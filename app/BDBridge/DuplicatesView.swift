import RecorderKit
import SwiftUI

/// Recordings that look like copies of one broadcast, with the copy to keep marked and the rest offered up.
struct DuplicatesView: View {
    let onOpen: (RecordedTitle) -> Void
    @Environment(AppModel.self) private var model

    @State private var confirming = false

    private var scanned: Bool {
        guard let job = model.job, case .scanning = job.kind else { return false }
        return job.finished
    }

    private var chosen: [RecordedTitle] {
        model.duplicates.flatMap(\.items).filter { model.duplicatePicks.contains($0.id) }
    }

    private var chosenGB: Double {
        chosen.reduce(0) { $0 + Double($1.sizeMB ?? 0) } / 1024
    }

    var body: some View {
        Group {
            if model.duplicates.isEmpty {
                prompt
            } else {
                list
            }
        }
        .alert("重複した \(chosen.count) 件を削除しますか？", isPresented: $confirming) {
            Button("\(chosen.count) 件を削除する", role: .destructive) {
                model.startBulk(.delete, ids: chosen.filter { !$0.protected }.map(\.id))
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(String(format: "合計 %.1fGB。各組で「残す」が付いたものは削除されません。\n"
                        + "レコーダーから削除され、元に戻せません。", chosenGB))
        }
    }

    private var prompt: some View {
        ContentUnavailableView {
            Label(scanned ? "重複はありませんでした" : "重複した録画を探す", systemImage: "square.on.square")
        } description: {
            Text("タイトルと長さが同じ録画について、番組内容をレコーダーから取得して照合します。"
                 + "1 件ずつ取得するため、初回は時間がかかります。")
        } actions: {
            Button(scanned ? "もう一度調べる" : "検出を開始") { model.startDuplicateScan() }
                .buttonStyle(.borderedProminent)
                .disabled(model.jobRunning || model.titles.isEmpty)
        }
    }

    private var list: some View {
        List {
            Section {
                Text("チェックが付いたものが削除候補です。先に放送されたものを残します。"
                     + "保護中や視聴途中のものがある場合は、そちらを残します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.duplicates) { set in
                Section {
                    ForEach(set.items) { title in
                        row(title, in: set)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(set.title).font(.subheadline).textCase(nil).lineLimit(2)
                        Text("\(set.items.count) 本 · \(String(format: "%.1fGB", set.sizeGB))"
                             + " · \(set.confidence.label)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if !chosen.isEmpty {
                Button(role: .destructive) {
                    confirming = true
                } label: {
                    Text(String(format: "選択した %d 件を削除（%.1fGB）", chosen.count, chosenGB))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.jobRunning)
                .padding(12)
                .background(.regularMaterial)
            }
        }
    }

    private func row(_ title: RecordedTitle, in set: DuplicateSet) -> some View {
        let keeping = title.id == set.keep
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if model.duplicatePicks.contains(title.id) {
                    model.duplicatePicks.remove(title.id)
                } else {
                    model.duplicatePicks.insert(title.id)
                }
            } label: {
                Image(systemName: model.duplicatePicks.contains(title.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(title.protected ? .secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(title.protected)

            Button { onOpen(title) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(keeping ? "残す" : "候補")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(keeping ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill))
                            .foregroundStyle(keeping ? Color.accentColor : .secondary)
                            .clipShape(Capsule())
                        Text(set.reasons[title.id] ?? "").font(.caption2).foregroundStyle(.secondary)
                        if title.protected {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(Format.dateTime.string(from: title.start)).font(.footnote)
                    HStack(spacing: 6) {
                        Text(model.channelName(for: title))
                        Text(Format.duration(title.durationSec))
                        if let size = title.sizeMB { Text(String(format: "%.1fGB", Double(size) / 1024)) }
                        if let quality = title.qualityName { Text(quality) }
                        Text(title.watchState.label)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .rowHitArea()
            }
            .buttonStyle(.plain)
        }
    }
}
