import RecorderKit
import SwiftUI

/// One recording: what it is, playing it on the television, protecting it, and deleting it.
struct TitleSheet: View {
    let title: RecordedTitle
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var detail: (summary: String, details: [String])?
    @State private var confirmingDelete = false
    @State private var deleted = false

    /// The live copy, since protecting it changes the list underneath.
    private var current: RecordedTitle { model.titles.first { $0.id == title.id } ?? title }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(current.title).font(.headline)
                    LabeledContent("放送", value: model.channelName(for: current))
                    LabeledContent("録画", value: Format.dateTime.string(from: current.start))
                    LabeledContent("長さ", value: Format.duration(current.durationSec))
                    if let size = current.sizeMB {
                        LabeledContent("サイズ", value: String(format: "%.1f GB", Double(size) / 1024))
                    }
                    if let quality = current.qualityName {
                        LabeledContent("録画モード", value: Codes.qualityLabel[quality] ?? quality)
                    }
                    LabeledContent("視聴", value: viewing)
                    if let genre = current.genre?.label {
                        LabeledContent("ジャンル", value: genre)
                    }
                }

                Section("テレビで再生") {
                    Button {
                        Task { await model.play(current, "play") }
                    } label: {
                        Label("再生", systemImage: "play.fill")
                    }
                    Button {
                        Task { await model.play(current, "pause") }
                    } label: {
                        Label("一時停止 / 再開", systemImage: "pause.fill")
                    }
                    Button {
                        Task { await model.play(current, "stop") }
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    if model.needsPower {
                        Button {
                            Task { await model.powerOn() }
                        } label: {
                            Label("レコーダーの電源を入れる", systemImage: "power")
                        }
                        .foregroundStyle(.orange)
                    }
                    Text("レコーダーにつながったテレビに映ります。").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("自動削除しないように保護", isOn: Binding(
                        get: { current.protected },
                        set: { on in Task { await model.setProtected(current, on) } }))
                    .disabled(model.busy != nil)
                    Button("この録画を削除", role: .destructive) { confirmingDelete = true }
                        .disabled(current.protected || model.busy != nil)
                    if current.protected {
                        Text("保護されているので削除できません。保護を外してください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let detail, !detail.summary.isEmpty {
                    Section("番組内容") { Text(detail.summary) }
                }
                if let detail {
                    ForEach(Array(detail.details.enumerated()), id: \.offset) { _, text in
                        if !text.isEmpty { Section("詳細") { Text(text) } }
                    }
                }
                if let problem = model.problem {
                    Section { Text(problem).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("録画")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton() }
            .task { detail = await model.detail(of: title) }
            .confirmationDialog("この録画を削除しますか？", isPresented: $confirmingDelete,
                                titleVisibility: .visible, presenting: current) { title in
                Button("削除する", role: .destructive) {
                    Task { deleted = await model.delete(title) }
                }
                Button("やめる", role: .cancel) {}
            } message: { title in
                Text("\(title.title)\nレコーダーから消えます。元に戻せません。")
            }
            .onChange(of: deleted) { if $1 { dismiss() } }
        }
    }

    private var viewing: String {
        guard current.watchState == .partway, let resume = current.resumeSec else {
            return current.watchState.label
        }
        return "\(current.watchState.label)（\(resume / 60)分）"
    }
}
