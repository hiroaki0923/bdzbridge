import RecBridgeModel
import RecorderKit
import SwiftUI

/// One reservation as the device that holds it has it -- the recorder, or the television -- with the way to
/// change it and to undo it. What the sheet holds, offers, holds back and says, and what each press does, are
/// the model's (`ReservationSheetState`): this lays it out.
struct ReservationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: ReservationSheetState

    /// The sheet of a state the screen that opened it made and keeps: the reservations' and the search's. A
    /// presented sheet is made afresh for each state it is handed, so the one kept here is always the one handed in.
    init(sheet: ReservationSheetState) {
        _sheet = State(initialValue: sheet)
    }

    /// A sheet that makes its own state as it opens and lets it go as it closes, for one opened over another sheet
    /// that keeps nothing of it once it has gone: a programme's, to change its reservation.
    init(reservation: Reservation, model: AppModel) {
        self.init(sheet: ReservationSheetState(reservation: reservation, model: model))
    }

    private var reservation: Reservation { sheet.reservation }

    var body: some View {
        NavigationStack {
            List {
                // A television is never woken, so the recorder's waking is nothing to a row of its own.
                if !sheet.onTelevision { WakingSection() }
                Section {
                    Text(reservation.title).font(.headline)
                    LabeledContent(SheetWords.station, value: model.channelName(for: reservation))
                    LabeledContent(SheetWords.starts, value: Format.dateTime.string(from: reservation.start))
                    LabeledContent(SheetWords.length, value: Format.duration(reservation.durationSec))
                    if sheet.onTelevision {
                        televisionsValues
                    } else {
                        recordersValues
                    }
                }

                if reservation.recording || reservation.conflict || reservation.createdByRecorder {
                    Section {
                        if reservation.recording { Text(SheetWords.recordingLine).foregroundStyle(.red) }
                        if reservation.conflict { conflictRow }
                        if reservation.createdByRecorder {
                            Text(RecorderDriver.madeByItself)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let program = sheet.program, !program.summary.isEmpty {
                    Section(SheetWords.summaryHeading) { Text(program.summary) }
                }
                if let program = sheet.program, !program.extended.isEmpty {
                    Section(SheetWords.detailsHeading) { Text(program.extended) }
                }

                if let asking = sheet.asking {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(asking).font(.callout)
                        }
                    }
                }

                if sheet.changed {
                    Section {
                        Button(sheet.changeLabel) { sheet.sendTheChange() }
                            .disabled(sheet.holdsItsButtons)
                    } footer: {
                        Text(sheet.changeFooter)
                    }
                }

                Section {
                    Button(SheetWords.deleteReservationLabel, role: .destructive) { sheet.delete() }
                        .disabled(sheet.holdsItsButtons)
                }

                if let problem = model.problem(for: reservation.device) {
                    Section { Text(problem.asABody).foregroundStyle(.red).font(.callout) }
                }
            }
            .disabled(sheet.asking != nil)
            .navigationTitle(ReservationSheetState.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton().disabled(sheet.asking != nil) }
            .interactiveDismissDisabled(sheet.asking != nil)
            .task { await sheet.opened() }
            // One alert, because two on the same view is not something SwiftUI promises to honour, and asking and
            // reporting never happen at once. The red line further up the sheet was missed.
            .alert(sheet.askTitle, isPresented: Binding(get: { sheet.isAsking }, set: { if !$0 { sheet.askClosed() } })) {
                if sheet.asksBeforeDeleting {
                    Button(SheetWords.confirmDeleteLabel, role: .destructive) { sheet.confirmDelete() }
                    Button(SheetWords.cancelLabel, role: .cancel) {}
                } else {
                    Button(SheetWords.okLabel, role: .cancel) {}
                }
            } message: {
                Text(sheet.askMessage)
            }
            .onChange(of: sheet.done) { if $1 { dismiss() } }
            .closesWithItsDevice(reservation.device)
        }
    }

    /// What the recorder holds of it beyond the times, and the choices that can still be changed: the mode, the
    /// repeat, and the disk where there is one to move it to.
    @ViewBuilder
    private var recordersValues: some View {
        @Bindable var sheet = sheet
        if sheet.settled {
            LabeledContent(SheetWords.quality, value: sheet.qualityShown)
            LabeledContent(SheetWords.repeating, value: SheetWords.repeatShown(reservation))
        } else {
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
        }
        diskRow
        if let follows = reservation.followsItsProgramme {
            LabeledContent(ReservationSheetState.followsLabel, value: follows)
        }
        LabeledContent(ReservationSheetState.madeByLabel, value: reservation.madeBy)
        if let size = reservation.sizeMB {
            LabeledContent(ReservationSheetState.sizeLabel,
                           value: Format.gigabytes(megabytes: size, on: reservation.device))
        }
    }

    /// 録画先: a picker while there is a disk to move it between, and otherwise its disk as a value.
    @ViewBuilder
    private var diskRow: some View {
        let offered = sheet.diskChoices
        if !offered.isEmpty {
            Picker(SheetWords.disk, selection: Binding(get: { sheet.disk }, set: { sheet.pick(disk: $0) })) {
                ForEach(offered, id: \.destination) { choice in
                    Text(RecorderDisk.label(choice.destination, named: choice.name)).tag(choice.destination)
                }
            }
        } else if let shown = sheet.diskShown {
            LabeledContent(SheetWords.disk, value: shown)
        }
    }

    /// What a television's row says of how it records: the mode as a value, only when the row carries one, which a
    /// television's need not; and the repeat, a picker over what it can be changed to while there is anything, and
    /// otherwise a value. Who made it and how large it will be a television's row does not say, and that a
    /// reservation goes after its programme when the times change is known of the recorder only.
    @ViewBuilder
    private var televisionsValues: some View {
        @Bindable var sheet = sheet
        if let quality = sheet.qualityLabel {
            LabeledContent(SheetWords.quality, value: quality)
        }
        let offered = sheet.televisionsRepeats
        if offered.isEmpty {
            LabeledContent(SheetWords.repeating, value: SheetWords.repeatShown(reservation))
        } else {
            Picker(SheetWords.repeating, selection: $sheet.repeating) {
                ForEach(offered, id: \.self) { key in
                    Text(SheetWords.repeatLabel(key)).tag(key)
                }
            }
        }
    }

    /// The recorder's 重複, and the reservations at the same hours.
    private var conflictRow: some View {
        let others = sheet.overlapping
        return VStack(alignment: .leading, spacing: 4) {
            Text(ReservationSheetState.clashLine).foregroundStyle(Color.legibleOrange)
            if others.isEmpty {
                Text(ReservationSheetState.noneOverlapping)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(ReservationSheetState.overlappingHeading).font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(others) { other in
                    Text(other.line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .rowLinesInFull()
    }
}
