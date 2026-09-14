import RecorderKit
import SwiftUI

/// What the recorder has on its disk: a flat list, or the same recordings gathered into programmes.
struct RecordingsScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage("recordingsMode") private var mode = "list"
    @State private var opened: RecordedTitle?
    @State private var openedGroup: TitleGroup?

    private var grouped: Bool { mode == "groups" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filters
                Divider()
                JobBarView()
                content
            }
            .navigationTitle("録画")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("表示", selection: $mode) {
                        Text("一覧").tag("list")
                        Text("まとめ").tag("groups")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.loadTitles(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!model.connected || model.busy != nil || model.jobRunning)
                }
            }
            .task(id: model.connected) { await model.loadTitles() }
            .sheet(item: $opened) { TitleSheet(title: $0) }
            .sheet(item: $openedGroup) { group in
                GroupSheet(group: group) { opened = $0 }
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let storage = model.storage {
                    Text("残り \(Format.gigabytes(storage.free))")
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                if let busy = model.busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(grouped ? "\(model.titleGroups.count) 番組" : "\(model.shownTitles.count) 件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("すべて", on: model.titleGenre == nil) { model.titleGenre = nil }
                    ForEach(Array(Codes.genreLabel.keys).sorted(), id: \.self) { level in
                        if let count = model.titleGenreCounts[level], count > 0 {
                            chip("\(Codes.genreLabel[level] ?? "") \(count)", on: model.titleGenre == level) {
                                model.titleGenre = model.titleGenre == level ? nil : level
                            }
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AppModel.TitleSort.allCases, id: \.self) { sort in
                        chip(sort.label, on: model.titleSort == sort) { model.titleSort = sort }
                    }
                    Divider().frame(height: 18)
                    ForEach(WatchState.allCases, id: \.self) { state in
                        chip(state.label, on: model.titleState == state) {
                            model.titleState = model.titleState == state ? nil : state
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func chip(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(text, action: action)
            .font(.footnote)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(on ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
            .foregroundStyle(on ? Color.accentColor : Color.primary)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var content: some View {
        if !model.connected {
            ContentUnavailableView("レコーダーが未設定です", systemImage: "play.rectangle",
                                   description: Text("設定でレコーダーのアドレスを入れてください"))
        } else if model.busy != nil && model.titles.isEmpty {
            ContentUnavailableView {
                Label("読み込み中", systemImage: "play.rectangle")
            } description: {
                Text("レコーダーから録画一覧を取得しています")
            }
        } else if grouped {
            List(model.titleGroups) { group in
                Button { openedGroup = group } label: { GroupRowView(group: group) }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay { if model.titleGroups.isEmpty { ContentUnavailableView("録画はありません", systemImage: "play.rectangle") } }
        } else {
            List(model.shownTitles) { title in
                Button { opened = title } label: {
                    TitleRowView(title: title, channel: model.channelName(for: title))
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay { if model.shownTitles.isEmpty { ContentUnavailableView("録画はありません", systemImage: "play.rectangle") } }
        }
    }
}

struct TitleRowView: View {
    let title: RecordedTitle
    let channel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if title.protected { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                Text(title.title).font(.subheadline).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(Format.dateTime.string(from: title.start))
                if !channel.isEmpty { Text(channel) }
                Text(Format.duration(title.durationSec))
                if let size = title.sizeMB { Text(String(format: "%.1fGB", Double(size) / 1024)) }
                if let quality = title.qualityName { Text(quality) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(title.watchState.label)
                    .font(.caption2)
                    .foregroundStyle(title.watchState == .unwatched ? Color.accentColor : .secondary)
                if title.watchState == .partway {
                    ProgressView(value: title.resumeFraction)
                        .frame(width: 60)
                }
                if let genre = title.genre?.label {
                    Text(genre).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct GroupRowView: View {
    let group: TitleGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.name).font(.subheadline).lineLimit(2)
            HStack(spacing: 6) {
                Text("\(group.count) 件")
                Text(String(format: "%.1fGB", group.sizeGB))
                if group.newCount > 0 { Text("未視聴 \(group.newCount)").foregroundStyle(Color.accentColor) }
                if group.protectedCount > 0 { Text("🔒 \(group.protectedCount)") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text("\(Format.dateTime.string(from: group.earliest)) 〜 \(Format.dateTime.string(from: group.latest))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// One programme's recordings, with the selection that bulk work needs.
struct GroupSheet: View {
    let group: TitleGroup
    let onOpen: (RecordedTitle) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmingDelete = false

    private var members: [RecordedTitle] { model.members(of: group) }
    private var chosen: [RecordedTitle] { members.filter { selected.contains($0.id) } }
    private var chosenGB: Double { chosen.reduce(0) { $0 + Double($1.sizeMB ?? 0) } / 1024 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                JobBarView()
                if selecting { selectionBar }
                list
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "完了" : "選択") {
                        selecting.toggle()
                        selected = []
                    }
                    .disabled(members.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("この番組を全部保護") {
                            model.startBulk(.protecting(true), ids: members.map(\.id))
                        }
                        Button("この番組の保護を全部解除") {
                            model.startBulk(.protecting(false), ids: members.map(\.id))
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(model.jobRunning || members.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) { SheetCloseButton() }
            }
            .safeAreaInset(edge: .bottom) { if selecting, !chosen.isEmpty { actions } }
            .confirmationDialog("選択した \(chosen.count) 件を削除しますか？", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("\(chosen.count) 件を削除する", role: .destructive) {
                    model.startBulk(.delete, ids: chosen.filter { !$0.protected }.map(\.id))
                    selecting = false
                    selected = []
                }
                Button("やめる", role: .cancel) {}
            } message: {
                Text(String(format: "合計 %.1fGB。保護されているものは削除されません。\n"
                            + "レコーダーから消えます。元に戻せません。", chosenGB))
            }
        }
    }

    private var list: some View {
        List(members) { title in
            Button {
                if selecting {
                    toggle(title)
                } else {
                    dismiss()
                    onOpen(title)
                }
            } label: {
                HStack(spacing: 10) {
                    if selecting {
                        Image(systemName: selected.contains(title.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(title.protected ? .secondary : Color.accentColor)
                    }
                    TitleRowView(title: title, channel: model.channelName(for: title))
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
    }

    private var selectionBar: some View {
        HStack {
            Button("保護以外をすべて選択") {
                selected = Set(members.filter { !$0.protected }.map(\.id))
            }
            Button("選択解除") { selected = [] }
            Spacer()
            Text("\(chosen.count) 件").foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Text(String(format: "選択した %d 件を削除（%.1fGB）", chosen.count, chosenGB))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            HStack {
                Button("保護する") { bulkProtect(true) }
                Button("保護を解除") { bulkProtect(false) }
            }
            .buttonStyle(.bordered)
        }
        .disabled(model.jobRunning)
        .padding(12)
        .background(.regularMaterial)
    }

    private func toggle(_ title: RecordedTitle) {
        if selected.contains(title.id) {
            selected.remove(title.id)
        } else {
            selected.insert(title.id)
        }
    }

    private func bulkProtect(_ on: Bool) {
        model.startBulk(.protecting(on), ids: chosen.map(\.id))
        selecting = false
        selected = []
    }
}
