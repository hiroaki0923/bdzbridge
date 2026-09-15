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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(reservation.title).font(.headline)
                    LabeledContent("放送", value: model.channelName(for: reservation))
                    LabeledContent("開始", value: Format.dateTime.string(from: reservation.start))
                    LabeledContent("長さ", value: Format.duration(reservation.durationSec))
                    LabeledContent("録画モード", value: Codes.qualityLabel[reservation.qualityName ?? ""]
                                   ?? reservation.qualityName ?? "-")
                    LabeledContent("毎回録画", value: Codes.repeatLabel[reservation.repeatName ?? ""] ?? "しない")
                    if reservation.eventID != nil {
                        LabeledContent("番組追従", value: "時間が変わっても追いかけます")
                    }
                    LabeledContent("入れた人", value: reservation.createdByRecorder ? "レコーダー（おまかせ録画）"
                                   : reservation.createdByApp ? "アプリから" : "不明")
                    if let size = reservation.sizeMB {
                        LabeledContent("録画サイズ", value: String(format: "%.1f GB", Double(size) / 1024))
                    }
                }

                if reservation.recording || reservation.conflict || reservation.createdByRecorder {
                    Section {
                        if reservation.recording { Text("いま録画中です").foregroundStyle(.red) }
                        if reservation.conflict { Text("他の予約と重なっています").foregroundStyle(.orange) }
                        if reservation.createdByRecorder {
                            Text("レコーダーのおまかせ録画が入れた予約です。消してもレコーダーが入れ直すことがあります。"
                                 + "続けて入るのを止めるには、レコーダー本体でおまかせ録画の設定を変えてください。")
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
            .task { program = await model.program(for: reservation) }
            // One alert, because two on the same view is not something SwiftUI promises to honour, and
            // asking and reporting never happen at once. The red line further up the sheet was missed.
            .alert(failure == nil ? "この予約を取り消しますか？" : "うまくいきませんでした",
                   isPresented: Binding(get: { confirming || failure != nil },
                                        set: { if !$0 { confirming = false; failure = nil } })) {
                if failure == nil {
                    Button("取り消す", role: .destructive) {
                        Task {
                            done = await model.cancel(reservation)
                            if !done { failure = model.problem ?? "レコーダーが受け付けませんでした" }
                        }
                    }
                    Button("やめる", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: {
                if let failure {
                    Text(failure)
                } else {
                    Text("\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
                         + "レコーダーから消えます。"
                         + (reservation.createdByRecorder
                            ? "\nおまかせ録画が入れた予約なので、レコーダーが入れ直すことがあります。"
                            : ""))
                }
            }
            .onChange(of: done) { if $1 { dismiss() } }
        }
    }
}
