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
    /// Whether one of the sheet's own requests is out -- playback, the power, the protect, the delete -- which
    /// holds the sheet open until it is answered, so that what it came to is said here rather than lost with a
    /// closed sheet, and its controls from the press, before the recorder's line is up. Not its details, which
    /// are asked as it opens and may be left behind.
    @State private var asking = false

    /// The live copy, since protecting it changes the list underneath.
    private var current: RecordedTitle { model.titles.first { $0.id == title.id } ?? title }

    /// What the sheet asked for and did not come to pass, said in its alert: the recorder's answer, or why
    /// nothing was sent.
    private func say(_ came: Altered) {
        if case .notDone(let why) = came { failure = why }
    }

    /// Asks `operation` with the sheet held until it is answered, and says what it came to.
    private func ask(_ operation: @escaping @MainActor () async -> Altered) {
        asking = true
        Task {
            let came = await operation()
            asking = false
            say(came)
        }
    }

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
                    // Held off while the recorder works, and from the press until the sheet's own request is
                    // answered. 一時停止 is one toggle on the recorder, so a second tap while the first was still
                    // on its way resumed what the reader had meant to pause; and turning the recorder on to play
                    // takes long enough to invite a second tap too.
                    Group {
                        Button {
                            ask { await model.play(current, "play") }
                        } label: {
                            // The recorder cannot be told where to start: `play` begins at the beginning whatever
                            // position is sent (docs/xsrs-api.md). A recording watched partway says so on the
                            // button, rather than surprise a reader who expected to carry on where they left off.
                            Label(current.watchState == .partway ? "最初から再生" : "再生", systemImage: "play.fill")
                        }
                        Button {
                            ask { await model.play(current, "pause") }
                        } label: {
                            Label("一時停止 / 再開", systemImage: "pause.fill")
                        }
                        Button {
                            ask { await model.play(current, "stop") }
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                        }
                        if model.needsPower {
                            Button {
                                ask { await model.powerOn() }
                            } label: {
                                Label("レコーダーの電源を入れる", systemImage: "power")
                            }
                            .foregroundStyle(Color.legibleOrange)
                        }
                    }
                    .disabled(model.isBusy(for: .recorder) || asking)
                    Text("レコーダーに接続されたテレビで再生されます。").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("保護（自動削除の対象外にする）", isOn: Binding(
                        get: { current.protected },
                        set: { on in ask { await model.setProtected(current, on) } }))
                    .disabled(model.isBusy(for: .recorder) || asking)
                    // Offered only where the delete's own door would let it through, and why not said from there.
                    let whyNot = RecorderDriver.whyNot(deleting: current)
                    Button("この録画を削除", role: .destructive) { confirmingDelete = true }
                        .disabled(whyNot != nil || model.isBusy(for: .recorder) || asking)
                    if let whyNot {
                        Text(whyNot)
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
            // The strip, as on the screens, rather than the waking alone: turning the recorder on to play
            // takes as long as waking it, and the strip is what says how long it has been.
            .recorderActivity(inSheet: true)
            .navigationTitle("録画")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton().disabled(asking) }
            .interactiveDismissDisabled(asking)
            .task { detail = await model.detail(of: title) }
            // One alert does both jobs: two on the same view is not something SwiftUI promises to honour.
            .alert(failure == nil ? "この録画を削除しますか？" : "エラー",
                   isPresented: Binding(get: { confirmingDelete || failure != nil },
                                        set: { if !$0 { confirmingDelete = false; failure = nil } })) {
                if failure == nil {
                    Button("削除する", role: .destructive) {
                        let title = current
                        ask {
                            let came = await model.delete(title)
                            if case .done = came { deleted = true }
                            return came
                        }
                    }
                    .disabled(model.isBusy(for: .recorder))
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
            .closesWithItsRecorder()
        }
    }

    private var viewing: String {
        guard current.watchState == .partway, let resume = current.resumeSec else {
            return current.watchState.label
        }
        return "\(current.watchState.label)（\(resume / 60)分）"
    }
}
