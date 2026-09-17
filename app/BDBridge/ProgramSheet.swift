import RecorderKit
import SwiftUI

/// One programme: what it is, whether the recorder is already set to record it, and the two choices that go
/// with a new reservation.
struct ProgramSheet: View {
    let program: GuideProgramRow
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @AppStorage("defaultQuality") private var quality = "LSR"
    @State private var repeating = "none"
    @State private var conflicts: [Reservation]?
    @State private var checking = false
    /// What the one alert is for. Two alerts on the same view is not something SwiftUI promises to honour,
    /// and asking and reporting never happen at once. Reporting is in here because the red line at the foot
    /// of the sheet was below the fold: a reservation the recorder refused looked like nothing at all.
    private enum Ask {
        case reserve
        case cancel(Reservation)
        case failed(String)
        /// The recorder was not there, so the reservation is waiting instead of made.
        case queued

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }
    @State private var ask: Ask?
    @State private var done = false
    /// The reservation whose own sheet is open for changing it.
    @State private var editing: Reservation?

    private var reservation: Reservation? { model.reservation(for: program) }
    private var past: Bool { program.end <= Date() }

    /// A weekly repeat has to fall on the programme's own weekday, so only that one is offered.
    private var repeatOptions: [String] {
        ["none", "title", "daily", Codes.weekdayRepeat(for: program.start), "mon-fri", "mon-sat"]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(program.title).font(.headline)
                    LabeledContent("放送", value: program.serviceName)
                    LabeledContent("開始", value: Format.dateTime.string(from: program.start))
                    LabeledContent("長さ", value: Format.duration(program.durationSec))
                    if let genre = program.genre?.label {
                        LabeledContent("ジャンル", value: genre)
                    }
                }

                if let reservation {
                    Section("この番組は予約済みです") {
                        LabeledContent("録画モード", value: reservation.qualityName ?? "-")
                        LabeledContent("毎回録画",
                                       value: Codes.repeatLabel[reservation.repeatName ?? ""] ?? "しない")
                        if reservation.recording { Text("録画中です").foregroundStyle(.red) }
                        // Changing it happens on the reservation's own sheet rather than here, so there is
                        // one place that does it and one set of pickers to keep right.
                        if !reservation.recording {
                            Button("予約を変更する") { editing = reservation }
                        }
                        Button("予約を取り消す", role: .destructive) { ask = .cancel(reservation) }
                            .disabled(model.busy != nil)
                    }
                } else if !past {
                    Section("録画予約") {
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
                        conflictRow
                        // Alive even while the recorder is being woken, and alive while it cannot be
                        // reached at all: a reservation made now goes to the queue and is sent when the
                        // recorder next answers. A disabled button is the app refusing to take the one
                        // thing it can still do.
                        Button("録画予約する") { ask = .reserve }
                            .disabled(model.working)
                    }
                }

                if !program.summary.isEmpty {
                    Section("番組内容") { Text(program.summary) }
                }
                if !program.extended.isEmpty {
                    Section("詳細") { Text(program.extended) }
                }
                if let problem = model.problem {
                    Section { Text(problem).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("番組")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton() }
            .task(id: taskKey) { await check() }
            .sheet(item: $editing) { ReservationSheet(reservation: $0) }
            .alert(askTitle, isPresented: Binding(get: { ask != nil },
                                                  set: { if !$0 { ask = nil } }),
                   presenting: ask) { asked in
                switch asked {
                case .reserve:
                    Button("予約する") {
                        Task {
                            let ok = await model.reserve(program, quality: quality, repeating: repeating)
                            if !ok {
                                ask = .failed(model.problem ?? "レコーダーがエラーを返しました")
                            } else if model.queued != nil {
                                model.queued = nil
                                ask = .queued          // kept, not made: say so before the sheet closes
                            } else {
                                done = true
                            }
                        }
                    }
                case .cancel(let reservation):
                    Button("取り消す", role: .destructive) {
                        Task {
                            done = await model.cancel(reservation)
                            if !done { ask = .failed(model.problem ?? "レコーダーがエラーを返しました") }
                        }
                    }
                case .failed, .queued:
                    EmptyView()
                }
                if case .queued = asked {
                    Button("OK", role: .cancel) { done = true }
                } else {
                    Button(asked.isFailure ? "OK" : "キャンセル", role: .cancel) {}
                }
            } message: { asked in
                switch asked {
                case .reserve:
                    Text("\(Format.dateTime.string(from: program.start)) \(program.serviceName)\n"
                         + "\(Codes.qualityLabel[quality] ?? quality) · "
                         + "\(Codes.repeatLabel[repeating] ?? repeating)\n"
                         + (model.offline
                            ? "レコーダーに接続できないため、予約を端末に保存します。次につながったときに登録します。"
                            : "レコーダーに予約を登録します。"))
                case .cancel(let reservation):
                    Text("\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
                         + "レコーダーから削除されます。")
                case .failed(let reason):
                    Text(reason)
                case .queued:
                    Text("\(Format.dateTime.string(from: program.start)) \(program.serviceName)\n"
                         + "レコーダーに届かなかったので、予約を端末に保存しました。"
                         + "次にレコーダーにつながったときに登録します。予約タブで取り消せます。")
                }
            }
            .onChange(of: done) { if $1 { dismiss() } }
        }
    }

    private var askTitle: String {
        switch ask {
        case .cancel: "この予約を取り消しますか？"
        case .failed: "エラー"
        case .queued: "送信待ちにしました"
        case .reserve: model.offline ? "この番組を送信待ちにしますか？" : "この番組を録画予約しますか？"
        case nil: "この番組を録画予約しますか？"
        }
    }

    private var taskKey: String { "\(program.id)-\(quality)-\(repeating)" }

    @ViewBuilder
    private var conflictRow: some View {
        if checking {
            HStack { ProgressView().controlSize(.small); Text("重複を確認中").foregroundStyle(.secondary) }
        } else if let conflicts {
            if conflicts.isEmpty {
                Label("重複する予約はありません", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(conflicts.count) 件の予約と重複します", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
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

    private func check() async {
        guard reservation == nil, !past, model.connected else { return }
        checking = true
        conflicts = await model.conflicts(for: program, quality: quality, repeating: repeating)
        checking = false
    }
}
