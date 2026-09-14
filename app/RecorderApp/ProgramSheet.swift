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
    @State private var confirming = false
    @State private var cancelling = false
    @State private var done = false

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
                        if reservation.recording { Text("いま録画中です").foregroundStyle(.red) }
                        Button("予約を取り消す", role: .destructive) { cancelling = true }
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
                        Button("録画予約する") { confirming = true }
                            .disabled(model.busy != nil)
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
            .confirmationDialog("この番組を録画予約しますか？", isPresented: $confirming, titleVisibility: .visible) {
                Button("予約する") { Task { done = await model.reserve(program, quality: quality, repeating: repeating) } }
                Button("やめる", role: .cancel) {}
            } message: {
                Text("\(Format.dateTime.string(from: program.start)) \(program.serviceName)\n"
                     + "\(Codes.qualityLabel[quality] ?? quality) · "
                     + "\(Codes.repeatLabel[repeating] ?? repeating)\nレコーダーに反映されます。")
            }
            .confirmationDialog("この予約を取り消しますか？", isPresented: $cancelling, titleVisibility: .visible,
                                presenting: reservation) { reservation in
                Button("取り消す", role: .destructive) {
                    Task { done = await model.cancel(reservation) }
                }
                Button("やめる", role: .cancel) {}
            } message: { reservation in
                Text("\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
                     + "レコーダーから消えます。")
            }
            .onChange(of: done) { if $1 { dismiss() } }
        }
    }

    private var taskKey: String { "\(program.id)-\(quality)-\(repeating)" }

    @ViewBuilder
    private var conflictRow: some View {
        if checking {
            HStack { ProgressView().controlSize(.small); Text("重なりを確認中").foregroundStyle(.secondary) }
        } else if let conflicts {
            if conflicts.isEmpty {
                Label("重なる予約はありません", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(conflicts.count) 件の予約と重なります", systemImage: "exclamationmark.triangle")
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
