import RecorderKit
import SwiftUI

/// One reservation as the recorder holds it, with the way to undo it.
///
/// This does not go through the guide, so it works for a reservation whose programme has dropped out of the
/// eight days the recorder publishes, and for one that records by time only.
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
    @State private var saved = false

    private var past: Bool { reservation.end <= Date() }

    /// A weekly repeat has to fall on the programme's own weekday, so that is the only weekly one offered.
    private var repeatOptions: [String] {
        ["none", "title", "daily", Codes.weekdayRepeat(for: reservation.start), "mon-fri", "mon-sat"]
    }

    private var changed: Bool {
        quality != (reservation.qualityName ?? "") || repeating != (reservation.repeatName ?? "none")
    }

    var body: some View {
        NavigationStack {
            List {
                WakingSection()
                Section {
                    Text(reservation.title).font(.headline)
                    LabeledContent("放送", value: model.channelName(for: reservation))
                    LabeledContent("開始", value: Format.dateTime.string(from: reservation.start))
                    LabeledContent("長さ", value: Format.duration(reservation.durationSec))
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
                    if reservation.eventID != nil {
                        LabeledContent("番組追従", value: "時間が変わっても追いかけます")
                    }
                    LabeledContent("登録元", value: reservation.createdByRecorder ? "レコーダー（おまかせ録画）"
                                   : reservation.createdByApp ? "アプリから" : "不明")
                    if let size = reservation.sizeMB {
                        LabeledContent("録画サイズ", value: String(format: "%.1f GB", Double(size) / 1024))
                    }
                }

                if reservation.recording || reservation.conflict || reservation.createdByRecorder {
                    Section {
                        if reservation.recording { Text("録画中です").foregroundStyle(.red) }
                        if reservation.conflict { Text("他の予約と重複しています").foregroundStyle(Color.legibleOrange) }
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
                                saved = await model.update(reservation, quality: quality, repeating: repeating)
                                if !saved { failure = model.problem ?? "レコーダーがエラーを返しました" }
                            }
                        }
                        .disabled(model.busy != nil)
                    } footer: {
                        Text(reservation.eventID != nil
                             ? "番組追従はそのままです。"
                             : "時刻を指定した予約なので、録画モードと毎回録画だけを変えられます。")
                    }
                }

                Section {
                    Button("予約を取り消す", role: .destructive) { confirming = true }
                        .disabled(model.busy != nil)
                }

                if let problem = model.problem {
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
            .alert(failure == nil ? "この予約を取り消しますか？" : "エラー",
                   isPresented: Binding(get: { confirming || failure != nil },
                                        set: { if !$0 { confirming = false; failure = nil } })) {
                if failure == nil {
                    Button("取り消す", role: .destructive) {
                        Task {
                            done = await model.cancel(reservation)
                            if !done { failure = model.problem ?? "レコーダーがエラーを返しました" }
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
                         + "レコーダーから削除されます。"
                         + (reservation.createdByRecorder
                            ? "\nおまかせ・まる録による予約のため、レコーダーが再登録することがあります。"
                            : ""))
                }
            }
            .onChange(of: done) { if $1 { dismiss() } }
        }
    }
}
