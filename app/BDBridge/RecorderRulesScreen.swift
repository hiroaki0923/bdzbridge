import RecBridgeModel
import RecorderKit
import SwiftUI

/// The keyword conditions the recorder holds by itself (おまかせ・まる録). Made and removed from here, never
/// edited: a condition read over the LAN is missing the channel narrowing the recorder's own screen can set,
/// and writing it back would erase that.
struct RecorderRulesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var removing: RecorderRule?
    @State private var failure: String?

    /// One alert for both, as elsewhere: two on one view is not something SwiftUI promises to honour.
    private enum Shown {
        case confirm(RecorderRule)
        case failed(String)
    }

    private var shown: Shown? {
        if let failure { return .failed(failure) }
        if let removing { return .confirm(removing) }
        return nil
    }

    private var alertTitle: String {
        if case .failed = shown { return "エラー" }
        return "この条件を削除しますか？"
    }

    var body: some View {
        List {
            Section {
                listState
                ForEach(model.recorderRules) { rule in
                    RecorderRuleRow(rule: rule, disk: model.diskShown(rule))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("削除") { removing = rule }.tint(.red).disabled(model.isBusy(for: .recorder))
                        }
                }
            } footer: {
                Text("レコーダー本体が番組を自動で探して録画する条件です。アプリを閉じていても動作します。"
                     + "対象チャンネルの指定はレコーダー本体でのみ設定でき、ここには表示されません。")
            }
        }
        // The screens' strip, which a screen pushed onto a stack does not get from the one it came from.
        .recorderActivity()
        .navigationTitle("おまかせ・まる録")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("条件を追加")
                    .disabled(!model.connected || model.isBusy(for: .recorder))
            }
        }
        // As the recordings' pull-down: the list read again, or a connect.
        .refreshable { await model.refreshRecorderRules() }
        // Keyed on `connected`, and on what the read itself checks, since `connected` turns true while the
        // recorder is still marked silent: see `RecordingsScreen`.
        .task(id: model.connected && !model.offline) { await model.loadRecorderRules() }
        .sheet(isPresented: $adding) { RecorderRuleSheet() }
        // The condition picked for deletion is the last recorder's when its lists are let go of: see
        // `timesForgotten`. One being typed is nobody's yet, and stays.
        .onChange(of: model.timesForgotten) { removing = nil }
        .alert(alertTitle,
               isPresented: Binding(get: { shown != nil },
                                    set: { if !$0 { removing = nil; failure = nil } }),
               presenting: shown) { shown in
            switch shown {
            case .confirm(let rule):
                Button("削除する", role: .destructive) {
                    Task { if case .notDone(let why) = await model.removeRecorderRule(rule) { failure = why } }
                }
                .disabled(model.isBusy(for: .recorder))
                Button("キャンセル", role: .cancel) {}
            case .failed:
                Button("OK", role: .cancel) {}
            }
        } message: { shown in
            switch shown {
            case .confirm(let rule):
                Text("「\(rule.name)」をレコーダーから削除します。本体で設定した対象チャンネルの指定も削除されます。")
            case .failed(let text):
                Text(text.asABody)
            }
        }
    }

    /// Above the conditions, what the list is: empty only once the recorder has said so. A failed read is
    /// said even over a list read before, which is then what the recorder said last time rather than now.
    @ViewBuilder
    private var listState: some View {
        if let failure = model.recorderRulesFailure {
            VStack(alignment: .leading, spacing: 2) {
                Text("条件を読み込めませんでした")
                Text(failure.asABody).font(.caption).foregroundStyle(.secondary)
            }
        } else if model.recorderRules.isEmpty {
            if model.recorderRulesLoaded {
                Text("条件が登録されていません").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("読み込み中").foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RecorderRuleRow: View {
    let rule: RecorderRule
    /// The disk it records to, last on its line: only off the internal disk (`AppModel.diskShown`), so that
    /// nothing changes in a home with no USB disk.
    var disk: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.name)
            Text(details).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var details: String { rule.details(disk: disk) }
}

/// The form for a new condition, over what the recorder takes (`RecorderRuleDraft`). Keywords are rows rather
/// than one comma-separated field: the recorder holds several of them and of the exclusions, so they are a list,
/// and a list is what iOS puts on screen.
struct RecorderRuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The quality from the settings, and not written back: see `ProgramSheetState.quality`.
    @State private var draft = RecorderRuleDraft(quality: DefaultQuality.current)
    /// The disk the reader picked under 録画先, kept as picked, as on the programme's sheet
    /// (`ProgramSheetState.chosenDisk`): nil until a disk is picked, and the internal disk after one was refused for
    /// being no longer offered.
    @State private var chosenDisk: String?
    @State private var failure: String?
    /// Whether the registration is out: the sheet is held open until it is answered -- the wait for the recorder
    /// and for the USB slot among it -- so that what it came to is said here rather than lost with a closed sheet;
    /// and レコーダーに登録 is held from the press, before the recorder's line is up, so that a second press makes
    /// no second condition.
    @State private var asking = false

    private func remove(_ id: RecorderRuleDraft.Word.ID, from list: inout [RecorderRuleDraft.Word]) {
        list.removeAll { $0.id == id }
    }

    private var subGenres: [Int] { RecorderRuleDraft.subGenres(of: draft.genre) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($draft.keywords) { $word in
                        WordRow(placeholder: "キーワード", text: $word.text,
                                remove: draft.mayRemoveKeyword ? { remove(word.id, from: &draft.keywords) } : nil)
                    }
                    .onDelete { draft.keywords.remove(atOffsets: $0) }
                    if draft.mayAddKeyword {
                        Button("キーワードを追加", systemImage: "plus") { draft.keywords.append(.init()) }
                    }
                } header: {
                    Text("キーワード")
                } footer: {
                    if let problem = draft.problem {
                        Text(problem.asABody)
                    } else {
                        Text("番組名や番組内容に含まれる言葉です。\(RecorderRuleDraft.keywordLimit) つまで登録できます。")
                    }
                }

                Section {
                    ForEach($draft.excluded) { $word in
                        WordRow(placeholder: "除外ワード", text: $word.text,
                                remove: { remove(word.id, from: &draft.excluded) })
                    }
                    .onDelete { draft.excluded.remove(atOffsets: $0) }
                    if draft.mayAddExclusion {
                        Button("除外ワードを追加", systemImage: "plus") { draft.excluded.append(.init()) }
                    }
                    if draft.asksHowToCombine {
                        Picker("検索方法", selection: $draft.logic) {
                            ForEach(RecorderRuleDraft.logics, id: \.self) { Text($0.label).tag($0.code) }
                        }
                    }
                } header: {
                    Text("除外ワード")
                } footer: {
                    Text("この言葉を含む番組は録画しません。\(RecorderRuleDraft.excludedLimit) つまで登録できます。")
                }

                Section {
                    Picker("ジャンル", selection: $draft.genre) {
                        Text("指定しない").tag(Int?.none)
                        ForEach(RecorderRuleDraft.genres, id: \.self) { level in
                            Text(Codes.genreLabel[level] ?? "").tag(Int?.some(level))
                        }
                    }
                    if !subGenres.isEmpty {
                        Picker("サブジャンル", selection: $draft.subGenre) {
                            Text("すべて").tag(Int?.none)
                            ForEach(subGenres, id: \.self) { level2 in
                                Text(Codes.subGenre(level1: draft.genre, level2: level2) ?? "").tag(Int?.some(level2))
                            }
                        }
                    }
                    Picker("放送", selection: $draft.broadcastingScope) {
                        ForEach(RecorderRuleDraft.broadcastingScopes(guide: model.counts), id: \.self) {
                            Text($0.label).tag($0.code)
                        }
                    }
                    Picker("時間帯", selection: $draft.timeScope) {
                        ForEach(RecorderRuleDraft.timeScopes, id: \.self) { Text($0.label).tag($0.code) }
                    }
                    Picker("録画モード", selection: $draft.quality) {
                        ForEach(RecorderDriver.recordsIn, id: \.self) { code in
                            Text(Codes.qualityLabel[code] ?? code).tag(code)
                        }
                    }
                    NewDiskRow(chosen: $chosenDisk)
                } header: {
                    Text("絞り込み")
                } footer: {
                    Text("対象チャンネルの指定はレコーダー本体でのみ設定できます。条件の名前はレコーダーが自動で付けます。")
                }
            }
            .disabled(asking)
            // The strip, as on a recording's sheet: the registration's line from the press, the waking and the
            // wait for the USB slot, which the screen's strip under the sheet cannot be seen to say.
            .recorderActivity(inSheet: true)
            .navigationTitle("条件を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }.disabled(asking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("レコーダーに登録") {
                        asking = true
                        Task {
                            defer { asking = false }
                            let request = draft.request(to: chosenDisk)
                            switch await model.addRecorderRule(request) {
                            case .done:
                                dismiss()
                            case .notDone(let why):
                                failure = why
                                // Refused for a disk that cannot be had -- no longer offered, or not answered by
                                // the slot while it was waited for: the sheet goes back to the internal disk,
                                // named, for the reader to send again or leave.
                                if model.diskCannotBeHad(request.destination) {
                                    chosenDisk = RecorderDisk.internalID
                                }
                            }
                        }
                    }
                    .disabled(draft.problem != nil || model.isBusy(for: .recorder) || asking)
                }
            }
            .interactiveDismissDisabled(asking)
            .alert("エラー",
                   isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure?.asABody ?? "")
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
                .accessibilityLabel("この行を削除")
            }
        }
    }
}
