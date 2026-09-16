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
                if model.recorderRules.isEmpty {
                    Text("条件が登録されていません").foregroundStyle(.secondary)
                }
                ForEach(model.recorderRules) { rule in
                    RecorderRuleRow(rule: rule)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("削除") { removing = rule }.tint(.red)
                        }
                }
            } footer: {
                Text("レコーダー本体が番組を自動で探して録画する条件です。アプリを閉じていても動作します。"
                     + "対象チャンネルの指定はレコーダー本体でのみ設定でき、ここには表示されません。")
            }
        }
        .navigationTitle("おまかせ・まる録")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("条件を追加")
                    .disabled(!model.connected || model.busy != nil)
            }
        }
        .refreshable { await model.loadRecorderRules() }
        .task(id: model.connected) { await model.loadRecorderRules() }
        .sheet(isPresented: $adding) { RecorderRuleSheet() }
        .alert(alertTitle,
               isPresented: Binding(get: { shown != nil },
                                    set: { if !$0 { removing = nil; failure = nil } }),
               presenting: shown) { shown in
            switch shown {
            case .confirm(let rule):
                Button("削除する", role: .destructive) {
                    Task {
                        if await !model.removeRecorderRule(rule) {
                            failure = model.problem ?? "レコーダーがエラーを返しました"
                        }
                    }
                }
                Button("キャンセル", role: .cancel) {}
            case .failed:
                Button("OK", role: .cancel) {}
            }
        } message: { shown in
            switch shown {
            case .confirm(let rule):
                Text("「\(rule.name)」をレコーダーから削除します。本体で設定した対象チャンネルの指定も削除されます。")
            case .failed(let text):
                Text(text)
            }
        }
    }
}

struct RecorderRuleRow: View {
    let rule: RecorderRule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.name)
            Text(details).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts = [rule.keywords.joined(separator: "、")]
        if !rule.excluded.isEmpty { parts.append("除外: " + rule.excluded.joined(separator: "、")) }
        parts.append(rule.logic == "AND" ? "すべて含む" : "いずれか含む")
        parts.append(rule.broadcastingScopeLabel)
        parts.append(rule.timeScopeLabel)
        if let genre = rule.genreLabel { parts.append(genre) }
        if let quality = rule.qualityName { parts.append(Codes.qualityLabel[quality] ?? quality) }
        return parts.joined(separator: " · ")
    }
}

/// The form for a new condition. Keywords are rows rather than one comma-separated field: the recorder holds
/// five of them and two exclusions, so they are a list, and a list is what iOS puts on screen.
struct RecorderRuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var keywords: [Word] = [Word()]
    @State private var excluded: [Word] = []
    @State private var logic = "OR"
    @State private var genreLevel1 = -1   // -1: no genre
    @State private var genreLevel2 = -1   // -1: the whole level-1 genre
    @State private var broadcastingScope = "ALL"
    @State private var timeScope = "ALL"
    @AppStorage("defaultQuality") private var quality = "LSR"
    @State private var failure: String?

    /// A row of the list needs an identity of its own; the text alone would reorder rows as it is typed.
    struct Word: Identifiable {
        let id = UUID()
        var text = ""
    }

    private var words: [String] { keywords.map(\.text).map(clean).filter { !$0.isEmpty } }
    private var excludedWords: [String] { excluded.map(\.text).map(clean).filter { !$0.isEmpty } }
    private func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }

    private var subGenres: [Int] {
        genreLevel1 < 0 ? [] : (Codes.subGenreLabel[genreLevel1]?.keys.sorted() ?? [])
    }

    private var problem: String? {
        if words.isEmpty && genreLevel1 < 0 { return "キーワードかジャンルを指定してください" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($keywords) { $word in
                        TextField("キーワード", text: $word.text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .onDelete { keywords.remove(atOffsets: $0) }
                    if keywords.count < 5 {
                        Button("キーワードを追加", systemImage: "plus") { keywords.append(Word()) }
                    }
                } header: {
                    Text("キーワード")
                } footer: {
                    if let problem { Text(problem) } else { Text("番組名や番組内容に含まれる言葉です。5 つまで登録できます。") }
                }

                Section {
                    ForEach($excluded) { $word in
                        TextField("除外ワード", text: $word.text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .onDelete { excluded.remove(atOffsets: $0) }
                    if excluded.count < 2 {
                        Button("除外ワードを追加", systemImage: "plus") { excluded.append(Word()) }
                    }
                    if words.count > 1 {
                        Picker("検索方法", selection: $logic) {
                            Text("いずれかを含む").tag("OR")
                            Text("すべてを含む").tag("AND")
                        }
                    }
                } header: {
                    Text("除外ワード")
                } footer: {
                    Text("この言葉を含む番組は録画しません。2 つまで登録できます。")
                }

                Section {
                    Picker("ジャンル", selection: $genreLevel1) {
                        Text("指定しない").tag(-1)
                        ForEach(Codes.genreLabel.keys.sorted().filter { Codes.subGenreLabel[$0] != nil }, id: \.self) { level in
                            Text(Codes.genreLabel[level] ?? "").tag(level)
                        }
                    }
                    if !subGenres.isEmpty {
                        Picker("サブジャンル", selection: $genreLevel2) {
                            Text("すべて").tag(-1)
                            ForEach(subGenres, id: \.self) { level2 in
                                Text(Codes.subGenre(level1: genreLevel1, level2: level2) ?? "").tag(level2)
                            }
                        }
                    }
                    Picker("放送", selection: $broadcastingScope) {
                        Text("すべての放送").tag("ALL")
                        Text("地上放送").tag("TRD")
                        Text("BS放送").tag("BSD")
                        Text("CS放送").tag("CSD")
                        Text("BS4K放送").tag("ADVBSD")
                        Text("CS4K放送").tag("ADVCSD")
                    }
                    Picker("時間帯", selection: $timeScope) {
                        Text("すべての時間帯").tag("ALL")
                        Text("朝").tag("MORNING")
                        Text("昼").tag("AFTERNOON")
                        Text("夜").tag("NIGHT")
                        Text("深夜").tag("MIDNIGHT")
                    }
                    Picker("録画モード", selection: $quality) {
                        ForEach(Codes.qualityOrder, id: \.self) { code in
                            Text(Codes.qualityLabel[code] ?? code).tag(code)
                        }
                    }
                } header: {
                    Text("絞り込み")
                } footer: {
                    Text("対象チャンネルの指定はレコーダー本体でのみ設定できます。条件の名前はレコーダーが自動で付けます。")
                }
            }
            // a genre's sub-genres are its own, so the choice cannot survive a change of genre
            .onChange(of: genreLevel1) { genreLevel2 = -1 }
            .navigationTitle("条件を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("レコーダーに登録") {
                        Task {
                            let request = RecorderRuleRequest(keywords: words, excluded: excludedWords, logic: logic,
                                                              genreLevel1: genreLevel1 < 0 ? nil : genreLevel1,
                                                              genreLevel2: genreLevel2 < 0 ? nil : genreLevel2,
                                                              timeScope: timeScope, broadcastingScope: broadcastingScope,
                                                              qualityCode: Codes.quality[quality] ?? 240)
                            if await model.addRecorderRule(request) {
                                dismiss()
                            } else {
                                failure = model.problem ?? "レコーダーがエラーを返しました"
                            }
                        }
                    }
                    .disabled(problem != nil || model.busy != nil)
                }
            }
            .alert("エラー",
                   isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
    }
}
