import RecorderKit
import SwiftUI

/// One reservation as the device that holds it has it -- the recorder, or the television -- with the way to
/// undo it.
///
/// This does not go through the guide, so it works for a reservation whose programme has dropped out of the
/// eight days the recorder publishes, and for one that records by time only.
///
/// A television's is shown and deleted, and nothing more: nothing here changes one yet, so it has no choices
/// to make and no button that sends them. Whatever is held back, said in red or reported as a failure is the
/// row's own device's, and the other device's work and trouble are left out of it.
struct ReservationSheet: View {
    let reservation: Reservation
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var confirming = false
    @State private var failure: String?
    @State private var program: GuideProgramRow?
    @State private var done = false
    /// What the pickers hold, seeded from the recorder and compared against it to know whether to offer 変更.
    @State private var quality = ""
    @State private var repeating = ""
    /// The disk the reader moved it to, nil while it is left on its own, kept as picked: a move to a disk let
    /// go of since is refused when it is sent, not sent to another. Moved back, it is nil again, so that what
    /// the recorder holds it on is kept (`AppModel.update`).
    @State private var movedTo: String?
    @State private var saved = false

    private var past: Bool { reservation.end <= Date() }
    private var onTelevision: Bool { reservation.device == .tv }

    /// A weekly repeat has to fall on the programme's own weekday, so that is the only weekly one offered.
    private var repeatOptions: [String] {
        ["none", "title", "daily", Codes.weekdayRepeat(for: reservation.start), "mon-fri", "mon-sat"]
    }

    /// Never for a television's row, which has no pickers: what they are seeded with is not a choice made.
    private var changed: Bool {
        !onTelevision
            && (quality != (reservation.qualityName ?? "") || repeating != (reservation.repeatName ?? "none")
                || movedTo != nil)
    }

    /// The disks it can be moved between, while it can still be changed: none for a television's row, and none
    /// in a home with no USB disk, where no picker is drawn.
    private var diskChoices: [RecorderDisk] {
        past || reservation.recording ? [] : model.diskChoices(for: reservation)
    }

    var body: some View {
        NavigationStack {
            List {
                // A television is never woken, so the recorder's waking is nothing to a row of its own.
                if !onTelevision { WakingSection() }
                Section {
                    Text(reservation.title).font(.headline)
                    LabeledContent("放送", value: model.channelName(for: reservation))
                    LabeledContent("開始", value: Format.dateTime.string(from: reservation.start))
                    LabeledContent("長さ", value: Format.duration(reservation.durationSec))
                    if onTelevision {
                        televisionsValues
                    } else {
                        recordersValues
                    }
                }

                if reservation.recording || reservation.conflict || reservation.createdByRecorder {
                    Section {
                        if reservation.recording { Text("録画中です").foregroundStyle(.red) }
                        if reservation.conflict { conflictRow }
                        if reservation.createdByRecorder {
                            Text("おまかせ・まる録によって自動登録された予約です。削除してもレコーダーが再登録することがあります。"
                                 + "自動登録を止めるには、レコーダー本体でおまかせ・まる録の設定を変更してください。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let program, !program.summary.isEmpty {
                    Section("番組内容") { Text(program.summary) }
                }
                if let program, !program.extended.isEmpty {
                    Section("詳細") { Text(program.extended) }
                }

                if changed {
                    Section {
                        Button("変更をレコーダーに送る") {
                            Task {
                                let moved = movedTo
                                saved = await model.update(reservation, quality: quality, repeating: repeating,
                                                           disk: moved)
                                if !saved { failure = whatWentWrong }
                                // A move to a disk that cannot be had -- no longer offered, or not answered by
                                // the slot while it was waited for -- is forgotten: the reservation stays where
                                // the recorder holds it, and the picker offers what is left.
                                if let moved, model.diskCannotBeHad(moved) { movedTo = nil }
                            }
                        }
                        .disabled(model.isBusy(for: reservation.device))
                    } footer: {
                        Text(reservation.eventID != nil
                             ? "番組追従はそのままです。"
                             : diskChoices.isEmpty
                             ? "時刻を指定した予約なので、録画モードと毎回録画だけを変えられます。"
                             : "時刻を指定した予約なので、録画モード・毎回録画・録画先だけを変えられます。")
                    }
                }

                // 削除, the word the list's swipe and every other delete in the app use: 取り消す would stand
                // beside キャンセル in the dialog, two words for going back on something.
                Section {
                    Button("予約を削除", role: .destructive) { confirming = true }
                        .disabled(model.isBusy(for: reservation.device))
                }

                if let problem = model.problem(for: reservation.device) {
                    Section { Text(problem).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("予約")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton() }
            .task {
                quality = reservation.qualityName ?? Codes.qualityOrder.first ?? "LSR"
                repeating = reservation.repeatName ?? "none"
                program = await model.program(for: reservation)
            }
            .onChange(of: saved) { if $1 { dismiss() } }
            // One alert, because two on the same view is not something SwiftUI promises to honour, and
            // asking and reporting never happen at once. The red line further up the sheet was missed.
            .alert(failure == nil ? "この予約を削除しますか？" : "エラー",
                   isPresented: Binding(get: { confirming || failure != nil },
                                        set: { if !$0 { alertClosed() } })) {
                if failure == nil {
                    Button("削除する", role: .destructive) {
                        Task {
                            done = await model.cancel(reservation)
                            if !done { failure = whatWentWrong }
                        }
                    }
                    Button("キャンセル", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: {
                if let failure {
                    Text(failure)
                } else {
                    Text("\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
                         + "\(reservation.device.label)から削除されます。"
                         + (reservation.createdByRecorder
                            ? "\nおまかせ・まる録による予約のため、レコーダーが再登録することがあります。"
                            : ""))
                }
            }
            .onChange(of: done) { if $1 { dismiss() } }
            .closesWithItsDevice(reservation.device)
        }
    }

    /// The alert has been closed, whichever it was. For a television's row the report of a failed delete
    /// takes the sheet with it: the list was read again on the way, and the row this sheet holds may no
    /// longer be the television's, so trying again starts from the list. Looked at here and not in the
    /// button, before the report is cleared: closing the alert is what clears it.
    private func alertClosed() {
        if failure != nil, onTelevision { done = true }
        confirming = false
        failure = nil
    }

    /// What a change or a delete that failed is reported as: the line of the row's device, which is where
    /// its operations say what went wrong.
    private var whatWentWrong: String {
        model.problem(for: reservation.device) ?? "\(reservation.device.label)がエラーを返しました"
    }

    /// What the recorder holds of it beyond the times, and the choices that can still be changed: the mode, the
    /// repeat, and the disk where there is one to move it to.
    @ViewBuilder
    private var recordersValues: some View {
        if past || reservation.recording {
            LabeledContent("録画モード", value: Codes.qualityLabel[reservation.qualityName ?? ""]
                           ?? reservation.qualityName ?? "-")
            LabeledContent("毎回録画", value: Codes.repeatLabel[reservation.repeatName ?? ""] ?? "しない")
        } else {
            Picker("録画モード", selection: $quality) {
                ForEach(Codes.qualityOrder, id: \.self) { code in
                    Text(Codes.qualityLabel[code] ?? code).tag(code)
                }
            }
            Picker("毎回録画", selection: $repeating) {
                ForEach(repeatOptions, id: \.self) { key in
                    Text(Codes.repeatLabel[key] ?? key).tag(key)
                }
            }
        }
        diskRow
        if reservation.eventID != nil {
            LabeledContent("番組追従", value: "時間が変わっても追いかけます")
        }
        LabeledContent("登録元", value: reservation.createdByRecorder ? "レコーダー（おまかせ録画）"
                       : reservation.createdByApp ? "アプリから" : "不明")
        if let size = reservation.sizeMB {
            LabeledContent("録画サイズ", value: String(format: "%.1f GB", Double(size) / 1024))
        }
    }

    /// 録画先: a picker beside the mode and the repeat while there is a disk to move it between, which a
    /// reservation off the internal disk always has once its own is not offered -- the internal disk, and its
    /// own. Otherwise its disk as a value: the one moved to, still named once it is no longer offered, or its
    /// own when that is off the internal disk. Nothing in a home with no USB disk.
    @ViewBuilder
    private var diskRow: some View {
        let offered = diskChoices
        if !offered.isEmpty {
            Picker("録画先", selection: Binding(get: { movedTo ?? reservation.destination },
                                               set: { movedTo = $0 == reservation.destination ? nil : $0 })) {
                ForEach(offered, id: \.destination) { choice in
                    Text(RecorderDisk.label(choice.destination, named: choice.name)).tag(choice.destination)
                }
            }
        } else if let shown = movedTo.map(model.diskLabel) ?? model.diskShown(reservation) {
            LabeledContent("録画先", value: shown)
        }
    }

    /// What a television's row says of how it records, as values: the mode only when the row carries one,
    /// which a television's need not. Who made it and how large it will be a television's row does not say,
    /// and that a reservation goes after its programme when the times change is known of the recorder only.
    @ViewBuilder
    private var televisionsValues: some View {
        if let quality = reservation.qualityName {
            LabeledContent("録画モード", value: Codes.qualityLabel[quality] ?? quality)
        }
        LabeledContent("毎回録画", value: Codes.repeatLabel[reservation.repeatName ?? ""] ?? "しない")
    }

    /// The recorder's 重複, and the reservations at the same hours, by when, where and what: the recorder does
    /// not say which one it clashes with. See `AppModel.overlapping`.
    private var conflictRow: some View {
        let others = model.overlapping(reservation)
        return VStack(alignment: .leading, spacing: 4) {
            Text("他の予約と重複しています").foregroundStyle(Color.legibleOrange)
            if others.isEmpty {
                Text("読み込んだ予約一覧には、時間が重なる予約がありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("時間が重なる予約").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(others) { other in
                    Text("\(Format.dateTime.string(from: other.start))〜\(Format.time.string(from: other.end))"
                         + "　\(model.channelName(for: other))　\(other.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .rowLinesInFull()
    }
}
