import RecorderKit
import SwiftUI

/// Programmes still to come whose title or description matches, across every broadcasting type and all eight
/// days. It reads the cache, so it works away from home as well.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    // `-searchFor ニュース` fills the box at launch, which is how the results are checked without typing.
    @State private var query = UserDefaults.standard.string(forKey: "searchFor") ?? ""
    @State private var results: [GuideProgramRow] = []
    @State private var searching = false
    @State private var tapped: GuideProgramRow?

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label("番組を探す", systemImage: "magnifyingglass")
                    } description: {
                        Text("番組名か番組内容に含まれる言葉で、これから放送される 8 日分を探します。"
                             + "全角と半角、大文字と小文字は区別しません。")
                    }
                } else if searching {
                    ProgressView().controlSize(.large)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { program in
                        Button { tapped = program } label: {
                            ProgramRowView(program: program, logo: model.logo(for: program),
                                           reservation: model.reservation(for: program))
                                .rowHitArea()
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("検索").font(.subheadline.weight(.semibold))
                        if !results.isEmpty {
                            Text("\(results.count) 件").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "番組名・番組内容")
            // the task is cancelled whenever the text changes, so the wait is the debounce
            .task(id: query) {
                guard !query.isEmpty else {
                    results = []
                    return
                }
                searching = results.isEmpty
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                results = await model.search(query)
                searching = false
            }
            .sheet(item: $tapped) { ProgramSheet(program: $0) }
        }
    }
}
