import RecBridgeModel
import RecorderKit
import SwiftUI

/// One recording: what it is, playing it on the television, protecting it, and deleting it. What the sheet holds,
/// offers, holds back and says, and what each press does, are the model's (`TitleSheetState`): this lays it out.
struct TitleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: TitleSheetState

    /// The sheet of a state the screen that opened it made and keeps: the recordings' and the search's. A presented
    /// sheet is made afresh for each state it is handed, so the one kept here is always the one handed in.
    init(sheet: TitleSheetState) {
        _sheet = State(initialValue: sheet)
    }

    /// A sheet that makes its own state as it opens and lets it go as it closes, for one opened over another sheet
    /// that keeps nothing of it once it has gone: a programme's page, for one of its recordings.
    init(title: RecordedTitle, model: AppModel) {
        self.init(sheet: TitleSheetState(title: title, model: model))
    }

    private var current: RecordedTitle { sheet.current }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(current.title).font(.headline)
                    LabeledContent(SheetWords.station, value: model.channelName(for: current))
                    LabeledContent(TitleSheetState.recordedLabel, value: Format.dateTime.string(from: current.start))
                    if current.lengthKnown {
                        LabeledContent(SheetWords.length, value: Format.duration(current.durationSec))
                    }
                    if let size = current.sizeMB {
                        LabeledContent(TitleSheetState.sizeLabel,
                                       value: Format.gigabytes(megabytes: size, on: current.device))
                    }
                    if let quality = sheet.qualityLabel {
                        LabeledContent(SheetWords.quality, value: quality)
                    }
                    if let disk = model.diskShown(current) { LabeledContent(SheetWords.disk, value: disk) }
                    LabeledContent(TitleSheetState.viewingLabel, value: sheet.viewing)
                    if let genre = current.genre?.label {
                        LabeledContent(SheetWords.genre, value: genre)
                    }
                }

                if sheet.offersPlayback {
                    Section(TitleSheetState.playbackHeading) {
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
                                Label(TitleSheetState.pauseLabel, systemImage: "pause.fill")
                            }
                            Button {
                                sheet.play("stop")
                            } label: {
                                Label(TitleSheetState.stopLabel, systemImage: "stop.fill")
                            }
                            if sheet.offersPower {
                                Button {
                                    sheet.powerOn()
                                } label: {
                                    Label(TitleSheetState.powerLabel, systemImage: "power")
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
                    Button(TitleSheetState.deleteLabel, role: .destructive) { sheet.delete() }
                        .disabled(sheet.holdsDelete)
                    if let whyNot = sheet.whyNotDeleted {
                        Text(whyNot.asABody)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let detail = sheet.detail, !detail.summary.isEmpty {
                    Section(SheetWords.summaryHeading) { Text(detail.summary) }
                }
                if let detail = sheet.detail {
                    ForEach(Array(detail.details.enumerated()), id: \.offset) { _, text in
                        if !text.isEmpty { Section(SheetWords.detailsHeading) { Text(text) } }
                    }
                }
                if let problem = model.problem(for: current.device) {
                    Section { Text(problem.asABody).foregroundStyle(.red).font(.callout) }
                }
            }
            // The strip, as on the screens, rather than the waking alone: turning the recorder on to play
            // takes as long as waking it, and the strip is what says how long it has been.
            .recorderActivity(inSheet: true)
            .navigationTitle(TitleSheetState.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton().disabled(sheet.asking) }
            .interactiveDismissDisabled(sheet.asking)
            .task { await sheet.opened() }
            // One alert does both jobs: two on the same view is not something SwiftUI promises to honour.
            .alert(sheet.askTitle, isPresented: Binding(get: { sheet.isAsking }, set: { if !$0 { sheet.askClosed() } })) {
                if sheet.asksBeforeDeleting {
                    Button(SheetWords.confirmDeleteLabel, role: .destructive) { sheet.confirmDelete() }
                        .disabled(sheet.holdsConfirmingDelete)
                    Button(SheetWords.cancelLabel, role: .cancel) {}
                } else {
                    Button(SheetWords.okLabel, role: .cancel) {}
                }
            } message: {
                Text(sheet.askMessage)
            }
            .onChange(of: sheet.done) { if $1 { dismiss() } }
            .closesWithItsDevice(sheet.title.device)
        }
    }
}
