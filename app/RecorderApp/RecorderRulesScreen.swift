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
        if case .failed = shown { return "うまくいきませんでした" }
        return "この条件を削除しますか？"
    }

    var body: some View {
        List {
            Section {
                if model.recorderRules.isEmpty {
                    Text("条件はありません").foregroundStyle(.secondary)
                }
                ForEach(model.recorderRules) { rule in
                    RecorderRuleRow(rule: rule)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("削除") { removing = rule }.tint(.red)
                        }
                }
            } footer: {
                Text("レコーダー本体が自分で番組を探して録画する条件です。アプリを閉じていても働きます。"
                     + "対象チャンネルの絞り込みは本体でしか設定できず、ここには出ません。")
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
                            failure = model.problem ?? "レコーダーが受け付けませんでした"
                        }
                    }
                }
                Button("やめる", role: .cancel) {}
            case .failed:
                Button("OK", role: .cancel) {}
            }
        } message: { shown in
            switch shown {
            case .confirm(let rule):
                Text("「\(rule.name)」がレコーダーから消えます。本体で設定したチャンネルの絞り込みも一緒に消えます。")
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

/// The form for a new condition. Keywords go in one field, separated by 、 or spaces, up to five, as the
/// recorder's own screen allows.
struct RecorderRuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var keywords = ""
    @State private var excluded = ""
    @State private var logic = "OR"
    @State private var broadcastingScope = "ALL"
    @State private var timeScope = "ALL"
    @AppStorage("defaultQuality") private var quality = "LSR"
    @State private var failure: String?

    private var words: [String] { split(keywords) }
    private var excludedWords: [String] { split(excluded) }

    private func split(_ text: String) -> [String] {
        text.split(whereSeparator: { "、,\u{3000} \n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var problem: String? {
        if words.isEmpty { return "キーワードを入れてください" }
        if words.count > 5 { return "キーワードは 5 つまでです" }
        if excludedWords.count > 2 { return "除外ワードは 2 つまでです" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("キーワード（、区切りで最大 5 つ）", text: $keywords)
                    TextField("除外ワード（最大 2 つ）", text: $excluded)
                    Picker("検索方法", selection: $logic) {
                        Text("いずれかのキーワードを含む").tag("OR")
                        Text("すべてのキーワードを含む").tag("AND")
                    }
                } footer: {
                    if let problem { Text(problem) }
                }
                Section {
                    Picker("放送", selection: $broadcastingScope) {
                        Text("すべての放送").tag("ALL")
                        Text("地上放送").tag("TRD")
                    }
                    Picker("時間帯", selection: $timeScope) {
                        Text("すべての時間帯").tag("ALL")
                        Text("夜").tag("NIGHT")
                    }
                    Picker("録画モード", selection: $quality) {
                        ForEach(Codes.qualityOrder, id: \.self) { code in
                            Text(Codes.qualityLabel[code] ?? code).tag(code)
                        }
                    }
                } footer: {
                    Text("対象チャンネルの絞り込みは本体でのみ設定できます。条件の名前はレコーダーが付けます。")
                }
            }
            .navigationTitle("条件を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("本体に登録") {
                        Task {
                            let request = RecorderRuleRequest(keywords: words, excluded: excludedWords, logic: logic,
                                                              timeScope: timeScope, broadcastingScope: broadcastingScope,
                                                              qualityCode: Codes.quality[quality] ?? 240)
                            if await model.addRecorderRule(request) {
                                dismiss()
                            } else {
                                failure = model.problem ?? "レコーダーが受け付けませんでした"
                            }
                        }
                    }
                    .disabled(problem != nil || model.busy != nil)
                }
            }
            .alert("うまくいきませんでした",
                   isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
    }
}
