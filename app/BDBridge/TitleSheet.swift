import RecorderKit
import SwiftUI

/// One recording: what it is, playing it on the television, protecting it, and deleting it.
struct TitleSheet: View {
    let title: RecordedTitle
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var detail: (summary: String, details: [String])?
    @State private var confirmingDelete = false
    @State private var failure: String?
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
                    LabeledContent("視聴状態", value: current.recording ? "録画中" : viewing)
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
                    Text("レコーダーに接続されたテレビで再生されます。").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("保護（自動削除の対象外にする）", isOn: Binding(
                        get: { current.protected },
                        set: { on in
                            Task {
                                if await !model.setProtected(current, on) {
                                    failure = model.problem ?? "レコーダーがエラーを返しました"
                                }
                            }
                        }))
                    .disabled(model.busy != nil)
                    Button("この録画を削除", role: .destructive) { confirmingDelete = true }
                        .disabled(current.protected || current.recording || model.busy != nil)
                    if current.recording {
                        Text("録画中のため削除できません。番組が終わるまでお待ちください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if current.protected {
                        Text("保護されているため削除できません。先に保護を解除してください。")
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
            // One alert does both jobs: two on the same view is not something SwiftUI promises to honour.
            .alert(failure == nil ? "この録画を削除しますか？" : "エラー",
                   isPresented: Binding(get: { confirmingDelete || failure != nil },
                                        set: { if !$0 { confirmingDelete = false; failure = nil } })) {
                if failure == nil {
                    Button("削除する", role: .destructive) {
                        Task {
                            deleted = await model.delete(current)
                            if !deleted { failure = model.problem ?? "レコーダーがエラーを返しました" }
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
                    Text("\(current.title)\nレコーダーから削除され、元に戻せません。")
                }
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
