import RecBridgeModel
import RecorderKit
import SwiftUI

/// One recording: what it is, playing it on the television, protecting it, and deleting it. What the sheet holds,
/// offers, holds back and says, and what each press does, are the model's (`TitleSheetState`): this lays it out.
struct TitleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: TitleSheetState

    init(title: RecordedTitle, model: AppModel) {
        _sheet = State(initialValue: TitleSheetState(title: title, model: model))
    }

    private var current: RecordedTitle { sheet.current }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(current.title).font(.headline)
                    LabeledContent("放送", value: model.channelName(for: current))
                    LabeledContent("録画", value: Format.dateTime.string(from: current.start))
                    if current.lengthKnown { LabeledContent("長さ", value: Format.duration(current.durationSec)) }
                    if let size = current.sizeMB {
                        LabeledContent("サイズ", value: Format.gigabytes(megabytes: size, on: current.device))
                    }
                    if let quality = current.qualityName {
                        LabeledContent("録画モード", value: Codes.qualityLabel[quality] ?? quality)
                    }
                    if let disk = model.diskShown(current) { LabeledContent("録画先", value: disk) }
                    LabeledContent("視聴状態", value: sheet.viewing)
                    if let genre = current.genre?.label {
                        LabeledContent("ジャンル", value: genre)
                    }
                }

                if sheet.offersPlayback {
                    Section("テレビで再生") {
                        Group {
                            Button {
                                sheet.play("play")
                            } label: {
                                Label(sheet.playLabel, systemImage: "play.fill")
                            }
                            .disabled(sheet.whyNotPlayed != nil)
                            Button {
                                sheet.play("pause")
                            } label: {
                                Label("一時停止 / 再開", systemImage: "pause.fill")
                            }
                            Button {
                                sheet.play("stop")
                            } label: {
                                Label("停止", systemImage: "stop.fill")
                            }
                            if sheet.offersPower {
                                Button {
                                    sheet.powerOn()
                                } label: {
                                    Label("レコーダーの電源を入れる", systemImage: "power")
                                }
                                .foregroundStyle(Color.legibleOrange)
                            }
                        }
                        .disabled(sheet.holdsPlayback)
                        Text(sheet.playbackNote.asABody)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle(sheet.protectLabel, isOn: Binding(get: { current.protected },
                                                             set: { sheet.setProtected($0) }))
                    .disabled(sheet.holdsProtect)
                    Button("この録画を削除", role: .destructive) { sheet.delete() }
                        .disabled(sheet.holdsDelete)
                    if let whyNot = sheet.whyNotDeleted {
                        Text(whyNot.asABody)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let detail = sheet.detail, !detail.summary.isEmpty {
                    Section("番組内容") { Text(detail.summary) }
                }
                if let detail = sheet.detail {
                    ForEach(Array(detail.details.enumerated()), id: \.offset) { _, text in
                        if !text.isEmpty { Section("詳細") { Text(text) } }
                    }
                }
                if let problem = model.problem(for: current.device) {
                    Section { Text(problem.asABody).foregroundStyle(.red).font(.callout) }
                }
            }
            // The strip, as on the screens, rather than the waking alone: turning the recorder on to play
            // takes as long as waking it, and the strip is what says how long it has been.
            .recorderActivity(inSheet: true)
            .navigationTitle("録画")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton().disabled(sheet.asking) }
            .interactiveDismissDisabled(sheet.asking)
            .task { await sheet.opened() }
            // One alert does both jobs: two on the same view is not something SwiftUI promises to honour.
            .alert(sheet.askTitle, isPresented: Binding(get: { sheet.isAsking }, set: { if !$0 { sheet.askClosed() } })) {
                if sheet.asksBeforeDeleting {
                    Button("削除する", role: .destructive) { sheet.confirmDelete() }
                        .disabled(sheet.holdsConfirmingDelete)
                    Button("キャンセル", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: {
                Text(sheet.askMessage)
            }
            .onChange(of: sheet.done) { if $1 { dismiss() } }
            .closesWithItsDevice(sheet.title.device)
        }
    }
}
