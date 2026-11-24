import RecBridgeModel
import RecorderKit
import SwiftUI

/// The keyword conditions the recorder holds by itself (おまかせ・まる録). Made and removed from here, never
/// edited: a condition read over the LAN is missing the channel narrowing the recorder's own screen can set,
/// and writing it back would erase that.
struct RecorderRulesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    /// What is swiped and asked here, and what is said over the list: the model's (`RecorderRulesState`).
    @State private var state: RecorderRulesState

    init(model: AppModel) {
        _state = State(initialValue: RecorderRulesState(model: model))
    }

    var body: some View {
        List {
            Section {
                listState
                ForEach(model.recorderRules) { rule in
                    RecorderRuleRow(rule: rule, details: state.details(of: rule))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(RecorderRulesState.deleteLabel) { state.delete(rule) }
                                .tint(.red)
                                .disabled(state.holdsDeleting)
                        }
                }
            } footer: {
                Text(RecorderRulesState.footer)
            }
        }
        // The screens' strip, which a screen pushed onto a stack does not get from the one it came from.
        .recorderActivity()
        .navigationTitle(RecorderRulesState.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(RecorderRulesState.addLabel)
                    .disabled(state.holdsAdding)
            }
        }
        // As the recordings' pull-down: the list read again, or a connect.
        .refreshable { await model.refreshRecorderRules() }
        // Keyed on `connected`, and on what the read itself checks, since `connected` turns true while the
        // recorder is still marked silent: see `RecordingsScreen`.
        .task(id: model.connected && !model.offline) { await model.loadRecorderRules() }
        .sheet(isPresented: $adding) { RecorderRuleSheet(model: model) }
        .onChange(of: model.timesForgotten) { state.recordersListsLetGo() }
        .alert(state.askTitle,
               isPresented: Binding(get: { state.ask != nil }, set: { if !$0 { state.askClosed() } }),
               presenting: state.ask) { asked in
            if let action = state.actionLabel(for: asked) {
                Button(action.label, role: action.destructive ? .destructive : nil) { state.act(on: asked) }
                    .disabled(state.holdsTheAction(for: asked))
            }
            Button(state.closingLabel(for: asked), role: .cancel) {}
        } message: { asked in
            Text(state.message(for: asked))
        }
    }

    /// Above the conditions, what the list is (`RecorderRulesState.listSays`).
    @ViewBuilder
    private var listState: some View {
        switch state.listSays {
        case .failed(let why):
            VStack(alignment: .leading, spacing: 2) {
                Text(RecorderRulesState.couldNotRead)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
        case .empty:
            Text(RecorderRulesState.noConditions).foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(RecorderRulesState.loading).foregroundStyle(.secondary)
            }
        case .nothing:
            EmptyView()
        }
    }
}

struct RecorderRuleRow: View {
    let rule: RecorderRule
    /// What its row says under its name, the disk it records to among it (`RecorderRulesState.details(of:)`).
    let details: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.name)
            Text(details).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// The form for a new condition, over what the recorder takes (`RecorderRuleDraft`). Keywords are rows rather
/// than one comma-separated field: the recorder holds several of them and of the exclusions, so they are a list,
/// and a list is what iOS puts on screen.
struct RecorderRuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The condition as typed, its disk and its registration: the model's (`RecorderRuleSheetState`).
    @State private var sheet: RecorderRuleSheetState

    init(model: AppModel) {
        _sheet = State(initialValue: RecorderRuleSheetState(model: model))
    }

    var body: some View {
        @Bindable var sheet = sheet
        NavigationStack {
            Form {
                Section {
                    ForEach($sheet.draft.keywords) { $word in
                        WordRow(placeholder: RecorderRuleSheetState.keywordPlaceholder, text: $word.text,
                                remove: sheet.draft.mayRemoveKeyword ? { sheet.removeKeyword(word.id) } : nil)
                    }
                    .onDelete { sheet.draft.keywords.remove(atOffsets: $0) }
                    if sheet.draft.mayAddKeyword {
                        Button(RecorderRuleSheetState.addKeywordLabel, systemImage: "plus") { sheet.addKeyword() }
                    }
                } header: {
                    Text(RecorderRuleSheetState.keywordHeading)
                } footer: {
                    Text(sheet.keywordFooter)
                }

                Section {
                    ForEach($sheet.draft.excluded) { $word in
                        WordRow(placeholder: RecorderRuleSheetState.excludedPlaceholder, text: $word.text,
                                remove: { sheet.removeExclusion(word.id) })
                    }
                    .onDelete { sheet.draft.excluded.remove(atOffsets: $0) }
                    if sheet.draft.mayAddExclusion {
                        Button(RecorderRuleSheetState.addExclusionLabel, systemImage: "plus") { sheet.addExclusion() }
                    }
                    if sheet.draft.asksHowToCombine {
                        Picker(RecorderRuleSheetState.logicLabel, selection: $sheet.draft.logic) {
                            ForEach(RecorderRuleDraft.logics, id: \.self) { Text($0.label).tag($0.code) }
                        }
                    }
                } header: {
                    Text(RecorderRuleSheetState.excludedHeading)
                } footer: {
                    Text(RecorderRuleSheetState.excludedFooter)
                }

                Section {
                    Picker(SheetWords.genre, selection: $sheet.draft.genre) {
                        Text(RecorderRuleSheetState.anyGenreLabel).tag(Int?.none)
                        ForEach(RecorderRuleDraft.genres, id: \.self) { level in
                            Text(Codes.genreLabel[level] ?? "").tag(Int?.some(level))
                        }
                    }
                    if !sheet.subGenres.isEmpty {
                        Picker(RecorderRuleSheetState.subGenreLabel, selection: $sheet.draft.subGenre) {
                            Text(RecorderRuleSheetState.allSubGenresLabel).tag(Int?.none)
                            ForEach(sheet.subGenres, id: \.self) { level2 in
                                Text(Codes.subGenre(level1: sheet.draft.genre, level2: level2) ?? "").tag(Int?.some(level2))
                            }
                        }
                    }
                    Picker(RecorderRuleSheetState.scopeLabel, selection: $sheet.draft.broadcastingScope) {
                        ForEach(sheet.broadcastingScopes, id: \.self) {
                            Text($0.label).tag($0.code)
                        }
                    }
                    Picker(RecorderRuleSheetState.timeLabel, selection: $sheet.draft.timeScope) {
                        ForEach(RecorderRuleDraft.timeScopes, id: \.self) { Text($0.label).tag($0.code) }
                    }
                    Picker(SheetWords.quality, selection: $sheet.draft.quality) {
                        ForEach(RecorderDriver.recordsIn, id: \.self) { code in
                            Text(Codes.qualityLabel[code] ?? code).tag(code)
                        }
                    }
                    NewDiskRow(chosen: $sheet.chosenDisk)
                } header: {
                    Text(RecorderRuleSheetState.narrowingHeading)
                } footer: {
                    Text(RecorderRuleSheetState.narrowingFooter)
                }
            }
            .disabled(sheet.asking)
            // The strip, as on a recording's sheet: the registration's line from the press, the waking and the
            // wait for the USB slot, which the screen's strip under the sheet cannot be seen to say.
            .recorderActivity(inSheet: true)
            .navigationTitle(RecorderRuleSheetState.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(SheetWords.cancelLabel) { dismiss() }.disabled(sheet.asking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(RecorderRuleSheetState.registerLabel) { sheet.register() }
                        .disabled(sheet.holdsRegistering)
                }
            }
            .interactiveDismissDisabled(sheet.asking)
            .onChange(of: sheet.done) { if sheet.done { dismiss() } }
            .alert(RecorderRuleSheetState.failureTitle,
                   isPresented: Binding(get: { sheet.failureMessage != nil }, set: { if !$0 { sheet.failureClosed() } })) {
                Button(SheetWords.okLabel, role: .cancel) {}
            } message: {
                Text(sheet.failureMessage ?? "")
            }
        }
    }
}

/// One word of a condition. The remove button is there because a swipe has to compete with the text field's
/// own handling of a horizontal drag, which makes it a poor way to offer the only means of deleting a row.
struct WordRow: View {
    let placeholder: String
    @Binding var text: String
    /// nil when this row gets no button: the only keyword row left.
    let remove: (() -> Void)?

    var body: some View {
        HStack {
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let remove {
                Button(role: .destructive, action: remove) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(RecorderRuleSheetState.removeRowLabel)
            }
        }
    }
}
