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
                    .disabled(!model.connected || model.busy != nil)
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

/// One programme's recordings.
struct GroupSheet: View {
    let group: TitleGroup
    let onOpen: (RecordedTitle) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(model.members(of: group)) { title in
                Button {
                    dismiss()
                    onOpen(title)
                } label: {
                    TitleRowView(title: title, channel: model.channelName(for: title))
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("閉じる") { dismiss() } }
        }
    }
}
