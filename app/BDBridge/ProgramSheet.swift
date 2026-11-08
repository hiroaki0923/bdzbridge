import RecBridgeModel
import RecorderKit
import SwiftUI

/// One programme: what it is, whether the recorder is already set to record it -- or will be, once a
/// reservation waiting on this phone reaches it -- and the two choices that go with a new reservation. What the
/// sheet holds, offers, holds back and says, and what each press does, are the model's (`ProgramSheetState`):
/// this lays it out.
struct ProgramSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: ProgramSheetState

    init(program: GuideProgramRow, model: AppModel) {
        _sheet = State(initialValue: ProgramSheetState(program: program, model: model))
    }

    private var program: GuideProgramRow { sheet.program }

    var body: some View {
        @Bindable var sheet = sheet
        NavigationStack {
            List {
                WakingSection()
                Section {
                    Text(program.title).font(.headline)
                    LabeledContent("放送", value: program.serviceName)
                    LabeledContent("開始", value: Format.dateTime.string(from: program.start))
                    LabeledContent("長さ", value: Format.duration(program.durationSec))
                    if let genre = program.genre?.label {
                        LabeledContent("ジャンル", value: genre)
                    }
                }

                if let reservation = sheet.reservation {
                    Section(sheet.recordersHeading) {
                        LabeledContent("録画モード", value: reservation.qualityName ?? "-")
                        LabeledContent("毎回録画",
                                       value: Codes.repeatLabel[reservation.repeatName ?? ""] ?? "しない")
                        if let shown = model.diskShown(reservation) { LabeledContent("録画先", value: shown) }
                        if reservation.recording { Text("録画中です").foregroundStyle(.red) }
                        if sheet.offersChanging(reservation) {
                            Button("予約を変更する") { sheet.change(reservation) }
                                .disabled(sheet.holdsTheRecordersButtons)
                        }
                        Button("予約を削除", role: .destructive) { sheet.delete(reservation) }
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
                    Section("録画予約") {
                        destinationRow(.recorder)
                        NewDiskRow(chosen: $sheet.chosenDisk)
                        Picker("録画モード", selection: $sheet.quality) {
                            ForEach(RecorderDriver.recordsIn, id: \.self) { code in
                                Text(Codes.qualityLabel[code] ?? code).tag(code)
                            }
                        }
                        Picker("毎回録画", selection: $sheet.repeating) {
                            ForEach(sheet.repeatOptions, id: \.self) { key in
                                Text(Codes.repeatLabel[key] ?? key).tag(key)
                            }
                        }
                        conflictRow
                        Button("録画予約する") { sheet.reserveOnTheRecorder() }
                            .disabled(sheet.holdsReservingOnTheRecorder)
                    }
                } else if sheet.offersAReservation(on: .tv) {
                    televisionOffer
                }

                if !program.summary.isEmpty {
                    Section("番組内容") { Text(program.summary) }
                }
                if !program.extended.isEmpty {
                    Section("詳細") { Text(program.extended) }
                }
                if let problem = model.problem(for: .recorder) {
                    Section { Text(problem.asABody).foregroundStyle(.red).font(.callout) }
                }
            }
            .disabled(sheet.asking != nil)
            .navigationTitle("番組")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton().disabled(sheet.holdsTheSheet) }
            .interactiveDismissDisabled(sheet.holdsTheSheet)
            .task(id: sheet.checkKey) { await sheet.check() }
            .task { await sheet.opened() }
            .onChange(of: sheet.device) { sheet.deviceChanged(to: $1) }
            .sheet(item: $sheet.editing) { ReservationSheet(reservation: $0) }
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
            .onChange(of: sheet.done) { if $1 { dismiss() } }
        }
    }

    /// 録画予約 for the television: the one mode it records in and the repeats it is sent for this programme.
    private var televisionOffer: some View {
        @Bindable var sheet = sheet
        return Section("録画予約") {
            destinationRow(.tv)
            LabeledContent("録画モード", value: Codes.qualityLabel[TVDriver.recordsIn] ?? TVDriver.recordsIn)
            Picker("毎回録画", selection: $sheet.repeating) {
                ForEach(sheet.televisionRepeatOptions, id: \.self) { key in
                    Text(Codes.repeatLabel[key] ?? key).tag(key)
                }
            }
            Button("録画予約する") { sheet.reserveOnTheTelevision() }
                .disabled(sheet.holdsReservingOnTheTelevision)
        }
    }

    /// 予約先: a choice with both devices free, one fixed line where the other holds the programme or has it
    /// waiting, and nothing in a home with one device.
    @ViewBuilder
    private func destinationRow(_ device: DeviceSlot) -> some View {
        if let free = sheet.destinationChoices {
            Picker("予約先", selection: Binding(get: { device }, set: { sheet.choose($0) })) {
                ForEach(free, id: \.self) { Text($0.label).tag($0) }
            }
        } else if sheet.showsTheDestinationAlone {
            LabeledContent("予約先", value: device.label)
        }
    }

    /// The television's reservation of this programme, under the television's name. What went wrong with the
    /// television is said under the button that ran into it, and not at the sheet's foot, which is the recorder's.
    private func televisionSection(_ reservation: Reservation) -> some View {
        Section(DeviceSlot.tv.label) {
            LabeledContent("毎回録画", value: Codes.repeatLabel[reservation.repeatName ?? ""] ?? "しない")
            if reservation.recording { Text("録画中です").foregroundStyle(.red) }
            if sheet.offersChanging(reservation) {
                Button("予約を変更する") { sheet.change(reservation) }
                    .disabled(sheet.holdsChangingTheTelevisions)
            }
            Button("予約を削除", role: .destructive) { sheet.delete(reservation) }
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
            LabeledContent("録画モード",
                           value: Codes.quality(code: waiting.request.qualityCode)
                               .map { Codes.qualityLabel[$0] ?? $0 } ?? "-")
            LabeledContent("毎回録画",
                           value: Codes.repeatLabel[Codes.repeatName(code: waiting.request.repeatCode) ?? ""]
                               ?? "しない")
            if let shown = model.diskShown(waiting) { LabeledContent("録画先", value: shown) }
            if let problem = waiting.problem {
                Text(problem.asABody).foregroundStyle(.red).font(.callout)
                Button("もう一度送る") { sheet.sendAgain(waiting) }
                    .disabled(sheet.holdsSendingAgain(waiting))
            } else {
                Text(PendingQueue.notYetAt(waiting.target))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Button("送信待ちの予約を削除", role: .destructive) { sheet.deleteWaiting(waiting) }
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
                Label(RecorderDriver.noClashes, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(ProgramSheetState.clashes(conflicts.count), systemImage: "exclamationmark.triangle")
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
