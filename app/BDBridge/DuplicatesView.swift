import RecorderKit
import SwiftUI

/// Recordings that look like copies of one broadcast. A tick deletes, and whatever is left unticked is marked
/// as kept: the mark follows the ticks rather than the suggestion, so that it can never name a copy that is
/// about to go.
struct DuplicatesView: View {
    let onOpen: (RecordedTitle) -> Void
    @Environment(AppModel.self) private var model

    @State private var confirming = false

    private var scanned: Bool {
        guard let job = model.job, case .scanning = job.kind else { return false }
        return job.finished
    }

    /// What a delete would take: the ticked copies the recorder will part with.
    private var chosen: [RecordedTitle] {
        model.duplicates.flatMap(\.items).filter { Duplicates.deletable($0) && model.duplicatePicks.contains($0.id) }
    }

    /// Sets with every copy ticked. Nothing is deleted while there are any: see `Duplicates.emptied`.
    private var emptied: [DuplicateSet] {
        Duplicates.emptied(model.duplicates, picked: model.duplicatePicks)
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
        // One alert for both, since two on the same view is not something SwiftUI promises to honour.
        .alert(emptied.isEmpty ? "重複した \(chosen.count) 件を削除しますか？" : "1 本も残らない組があります",
               isPresented: $confirming) {
            if emptied.isEmpty {
                Button("\(chosen.count) 件を削除する", role: .destructive) {
                    model.startBulk(.delete, ids: chosen.map(\.id))
                }
                Button("キャンセル", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            if emptied.isEmpty {
                Text(String(format: "合計 %.1fGB。チェックの無いものは残ります。\n"
                            + "レコーダーから削除され、元に戻せません。", chosenGB))
            } else {
                Text(emptiedMessage)
            }
        }
    }

    /// Which sets would go entirely, by name, since the reader has to find them in the list to put it right.
    private var emptiedMessage: String {
        var names = emptied.prefix(3).map { "・\($0.title)" }
        if emptied.count > 3 { names.append("ほか \(emptied.count - 3) 組") }
        return "次の組はすべてにチェックが付いていて、削除すると 1 本も残りません。"
            + "残すものを選んで、チェックを外してください。\n\n" + names.joined(separator: "\n")
    }

    /// Candidates left out because their text has not been read yet: the scan was stopped, or the recorder
    /// could not give it. Scanning again reads only those.
    private var unread: String {
        "番組内容をまだ取得できていない録画が \(model.unreadDuplicates) 件あり、比べていません。"
    }

    private var prompt: some View {
        ContentUnavailableView {
            Label(!scanned ? "重複した録画を探す"
                  : model.unreadDuplicates > 0 ? "調べた範囲に重複はありませんでした" : "重複はありませんでした",
                  systemImage: "square.on.square")
        } description: {
            if scanned, model.unreadDuplicates > 0 {
                Text(unread)
            } else {
                Text("タイトルと長さが同じ録画について、番組内容をレコーダーから取得して照合します。"
                     + "1 件ずつ取得するため、初回は時間がかかります。")
            }
        } actions: {
            Button(scanned ? "もう一度調べる" : "検出を開始") { model.startDuplicateScan() }
                .buttonStyle(.borderedProminent)
                .disabled(model.jobRunning || model.titles.isEmpty)
        }
    }

    private var list: some View {
        List {
            Section {
                Text("チェックを付けたものを削除し、チェックの無いものは残します。番組内容も同じ組では、"
                     + "先に放送されたもの（保護中や視聴途中のものがあればそちら）を残して、ほかにチェックを付けています。"
                     + "内容を確かめられない組にはチェックを付けていません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.unreadDuplicates > 0 {
                Section {
                    Text(unread).font(.caption).foregroundStyle(.secondary)
                    Button("もう一度調べる") { model.startDuplicateScan() }
                        .disabled(model.jobRunning)
                }
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
        let deletable = Duplicates.deletable(title)
        let keeping = !(deletable && model.duplicatePicks.contains(title.id))
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if model.duplicatePicks.contains(title.id) {
                    model.duplicatePicks.remove(title.id)
                } else {
                    model.duplicatePicks.insert(title.id)
                }
            } label: {
                Image(systemName: keeping ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(deletable ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            // The recorder would refuse to delete it. And while a job runs the ticks stay as they are: a delete
            // is working from them, and a scan builds the sets again when it ends.
            .disabled(!deletable || model.jobRunning)

            Button { onOpen(title) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(keeping ? "残す" : "削除")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(keeping ? Color.accentColor.opacity(0.15) : Color.red.opacity(0.12))
                            .foregroundStyle(keeping ? Color.accentColor : .red)
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
