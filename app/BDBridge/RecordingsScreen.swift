import RecorderKit
import SwiftUI

/// What the recorder has on its disk: a flat list, or the same recordings gathered into programmes.
struct RecordingsScreen: View {
    @Environment(AppModel.self) private var model
    // A launch argument for this key pins it for the whole run: the argument domain outranks what is
    // written here, so a pick would appear to do nothing. See app/README.md.
    @AppStorage("recordingsMode") private var mode = "list"
    @State private var opened: RecordedTitle?
    @State private var openedGroup: TitleGroup?
    /// The row swiped, by id rather than by value: the recording is read back out of the model when the
    /// dialog asks, so a delete can only ever be sent for a row the list still holds.
    @State private var removing: String?
    @State private var failure: String?

    private var grouped: Bool { mode == "groups" }
    private var duplicating: Bool { mode == "dups" }

    /// One alert does both jobs, because two on the same view is not something SwiftUI promises to honour.
    private enum Shown {
        case confirm(RecordedTitle)
        case failed(String)
    }

    private var shown: Shown? {
        if let failure { return .failed(failure) }
        if let id = removing, let title = model.titles.first(where: { $0.id == id }) {
            return .confirm(title)
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                JobBarView()
                content
            }
            .recorderActivity()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("表示", selection: $mode) {
                            Label("一覧", systemImage: "list.bullet").tag("list")
                            Label("まとめ", systemImage: "rectangle.stack").tag("groups")
                            Label("重複", systemImage: "square.on.square").tag("dups")
                        }
                    } label: {
                        Image(systemName: duplicating ? "square.on.square"
                                                      : grouped ? "rectangle.stack" : "list.bullet")
                    }
                    .accessibilityLabel("表示を変える")
                }
                // the free space is worth a permanent place; the sort and the watch state are worth a menu
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(model.storage.map { "残り \(Format.gigabytes($0.free))" } ?? "録画")
                            .font(.subheadline.weight(.semibold))
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("ジャンル", selection: Binding(get: { model.titleGenre },
                                                            set: { model.titleGenre = $0 })) {
                            Text("すべて \(model.titles.count)").tag(Int?.none)
                            ForEach(Array(Codes.genreLabel.keys).sorted(), id: \.self) { level in
                                if let count = model.titleGenreCounts[level], count > 0 {
                                    Text("\(Codes.genreLabel[level] ?? "") \(count)").tag(Int?.some(level))
                                }
                            }
                        }
                        Picker("並び順", selection: Binding(get: { model.titleSort },
                                                         set: { model.titleSort = $0 })) {
                            ForEach(AppModel.TitleSort.allCases, id: \.self) { sort in
                                Text(sort.label).tag(sort)
                            }
                        }
                        Picker("視聴状態", selection: Binding(get: { model.titleState },
                                                         set: { model.titleState = $0 })) {
                            Text("すべて").tag(WatchState?.none)
                            ForEach(WatchState.allCases, id: \.self) { state in
                                Text(state.label).tag(WatchState?.some(state))
                            }
                        }
                    } label: {
                        Image(systemName: filtering ? "line.3.horizontal.decrease.circle.fill"
                                                    : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("ジャンル・並び順・視聴状態で絞り込む")
                }
            }
            .task(id: model.connected) { await model.loadTitles() }
            // pulling down reads the list again from the recorder; not while a bulk job is walking it
            // Pulling down while the app has given up on the recorder is the reader asking for another go
            // at it, which is the same thing the strip's 再接続 does.
            .refreshable {
                guard !model.jobRunning else { return }
                if model.offline { await model.connect() } else { await model.loadTitles(force: true) }
            }
            .sheet(item: $opened) { TitleSheet(title: $0) }
            .sheet(item: $openedGroup) { GroupSheet(group: $0) }
            .alert(shownTitle,
                   isPresented: Binding(get: { shown != nil },
                                        set: { if !$0 { removing = nil; failure = nil } }),
                   presenting: shown) { shown in
                switch shown {
                case .confirm(let title):
                    Button("削除する", role: .destructive) {
                        Task {
                            if await !model.delete(title) {
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
                case .confirm(let title): Text(Self.deleteMessage(title))
                case .failed(let reason): Text(reason)
                }
            }
        }
    }

    private var shownTitle: String {
        if case .failed = shown { return "エラー" }
        return "この録画を削除しますか？"
    }

    /// What is about to go, and how much of the disk it gives back. Said in full because there is no undo.
    static func deleteMessage(_ title: RecordedTitle) -> String {
        var lines = [title.title, Format.dateTime.string(from: title.start)]
        if let size = title.sizeMB { lines.append(String(format: "%.1f GB", Double(size) / 1024)) }
        return lines.joined(separator: "\n") + "\nレコーダーから削除され、元に戻せません。"
    }

    private var filtering: Bool {
        model.titleGenre != nil || model.titleState != nil || model.titleSort != .newest
    }

    /// What is being shown, since the filters now live behind a menu.
    private var subtitle: String {
        if let busy = model.busy { return busy }
        if duplicating { return "\(model.duplicates.count) 組の重複" }
        let what = grouped ? "\(model.titleGroups.count) 番組" : "\(model.shownTitles.count) 件"
        guard let genre = model.titleGenre, let label = Codes.genreLabel[genre] else { return what }
        return "\(label) · \(what)"
    }

    @ViewBuilder
    private var content: some View {
        if !model.connected {
            NoRecorderView(icon: "play.rectangle")
        } else if model.busy != nil && model.titles.isEmpty {
            ContentUnavailableView {
                Label("読み込み中", systemImage: "play.rectangle")
            } description: {
                Text("レコーダーから録画一覧を取得しています")
            }
        } else if duplicating {
            DuplicatesView { opened = $0 }
        } else if grouped {
            // Once for the list and its overlay: each read filters, sorts and groups every recording.
            let groups = model.titleGroups
            List(groups) { group in
                Button { openedGroup = group } label: { GroupRowView(group: group).rowHitArea() }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay { if groups.isEmpty { ContentUnavailableView("録画された番組はありません", systemImage: "play.rectangle") } }
        } else {
            let listed = model.shownTitles
            List(listed) { title in
                Button { opened = title } label: {
                    TitleRowView(title: title, channel: model.channelName(for: title),
                                 logo: model.logo(for: title)).rowHitArea()
                }
                .buttonStyle(.plain)
                .titleSwipe(title, ask: { removing = title.id },
                            unprotect: { Task { await model.setProtected(title, false) } })
            }
            .listStyle(.plain)
            .overlay { if listed.isEmpty { ContentUnavailableView("録画された番組はありません", systemImage: "play.rectangle") } }
        }
    }
}

extension View {
    /// The trailing swipe on a recording. It asks before deleting -- this is the recorder's disk and there
    /// is no undo -- so a full swipe is off: a flick should not be able to spend a recording.
    ///
    /// A protected recording cannot be deleted at all; the recorder refuses it. So rather than offering a
    /// button that can only fail, the swipe offers the thing that has to happen first, and deleting is one
    /// more swipe away.
    /// `title` is nil where the row should not be swipeable at all.
    func titleSwipe(_ title: RecordedTitle?, ask: @escaping () -> Void,
                    unprotect: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if title?.recording == true {
                // Nothing on offer: the recorder is writing to this one and refuses to delete it. The row
                // says 録画中, which is the answer to why there is no button here.
                EmptyView()
            } else if let title, title.protected {
                // `role: .destructive` would animate the row away as it is swiped, before there is an
                // answer, and it stays away when the answer is no. The colour is all that is wanted.
                Button("保護解除") { unprotect() }.tint(Color.legibleOrange)
            } else if title != nil {
                Button("削除") { ask() }.tint(.red)
            }
        }
    }
}

struct TitleRowView: View {
    let title: RecordedTitle
    let channel: String
    let logo: Data?

    @ScaledMetric(relativeTo: .caption2) private var logoHeight = 14.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading.lineLimit(2)
            meta.font(.caption2).foregroundStyle(.secondary)
            watching
        }
        .rowLinesInFull()
        .padding(.vertical, 2)
    }

    /// The title after the lock and 録画中, in one text for the same reason as the line under it: beside
    /// 録画中 the title was left a column a few characters wide.
    private var heading: Text {
        var line = Text(title.title).font(.subheadline)
        if title.recording {
            line = Text("録画中").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                + Text.rowGap.font(.caption2) + line
        }
        if title.protected {
            line = Text(Image(systemName: "lock.fill")).font(.caption2).foregroundStyle(.secondary)
                + Text.rowGap.font(.caption2) + line
        }
        return line
    }

    /// When, where and how big, as one line of text: as views side by side, a large text size squeezed each
    /// into a narrow column of its own.
    private var meta: Text {
        var parts = [Text(Format.dateTime.string(from: title.start))]
        // No space held for a missing logo, unlike the reservations: this one sits in the middle of the line,
        // where a held gap would read as something having gone wrong.
        if let logo = InlineLogo.text(logo, height: logoHeight) {
            parts.append(channel.isEmpty ? logo : logo + Text.rowGap + Text(channel))
        } else if !channel.isEmpty {
            parts.append(Text(channel))
        }
        parts.append(Text(Format.duration(title.durationSec)))
        if let size = title.sizeMB { parts.append(Text(String(format: "%.1fGB", Double(size) / 1024))) }
        if let quality = title.qualityName { parts.append(Text(quality)) }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text.rowGap + $1 }
    }

    /// Whether it has been watched, and the genre, which is in the secondary grey: it was fainter still, too
    /// faint to read. A recording watched partway has a bar between the two, which a line of text cannot
    /// hold, so when they do not fit side by side the bar goes under the words.
    @ViewBuilder
    private var watching: some View {
        let state = Text(title.watchState.label)
            .foregroundStyle(title.watchState == .unwatched ? Color.accentColor : Color.secondary)
        let genre = title.genre?.label.map { Text($0).foregroundStyle(.secondary) }
        if title.watchState == .partway {
            let bar = ProgressView(value: title.resumeFraction).frame(width: 60)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    state.font(.caption2)
                    bar
                    genre?.font(.caption2)
                }
                VStack(alignment: .leading, spacing: 4) {
                    (genre.map { state + Text.rowGap + $0 } ?? state).font(.caption2)
                    bar
                }
            }
        } else {
            (genre.map { state + Text.rowGap + $0 } ?? state).font(.caption2)
        }
    }
}

struct GroupRowView: View {
    let group: TitleGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.name).font(.subheadline).lineLimit(2)
            counts.font(.caption2).foregroundStyle(.secondary)
            // The secondary grey rather than fainter: it is what says how far back the programme goes.
            Text("\(Format.dateTime.string(from: group.earliest)) 〜 \(Format.dateTime.string(from: group.latest))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .rowLinesInFull()
        .padding(.vertical, 2)
    }

    /// How many, how big, and how many are new or protected, as one line of text that wraps as a line does.
    private var counts: Text {
        var line = Text("\(group.count) 件") + Text.rowGap + Text(String(format: "%.1fGB", group.sizeGB))
        if group.newCount > 0 {
            line = line + Text.rowGap + Text("未視聴 \(group.newCount)").foregroundStyle(Color.accentColor)
        }
        if group.protectedCount > 0 { line = line + Text.rowGap + Text("🔒 \(group.protectedCount)") }
        return line
    }
}

/// One programme's recordings, with the selection that bulk work needs.
struct GroupSheet: View {
    let group: TitleGroup
    @Environment(AppModel.self) private var model

    /// The episode opened, in a sheet over this one. It was handed to the screen underneath, which meant
    /// closing this sheet to open it: back from one episode, the reader was on the list of programmes and had
    /// to find the programme again for the next.
    @State private var opened: RecordedTitle?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmingDelete = false
    /// The row swiped, by id, read back out of the model when the dialog asks.
    @State private var removing: String?
    @State private var failure: String?

    /// One alert for all three jobs. Two on a view is not something SwiftUI promises to honour, and this
    /// one has a bulk delete, a single delete and a failure to report.
    private enum Shown {
        case bulk
        case one(RecordedTitle)
        case failed(String)
    }

    private func shown(among members: [RecordedTitle]) -> Shown? {
        if let failure { return .failed(failure) }
        if let id = removing, let title = members.first(where: { $0.id == id }) { return .one(title) }
        return confirmingDelete ? .bulk : nil
    }

    private static func gigabytes(_ titles: [RecordedTitle]) -> Double {
        titles.reduce(0) { $0 + Double($1.sizeMB ?? 0) } / 1024
    }

    var body: some View {
        // Read once here and handed to the parts that need them. Each read sorts every recording and picks
        // this programme's out of them, and every tick in the selection draws the sheet again; read wherever
        // they were wanted, that came to half a dozen reads a tap.
        let members = model.members(of: group)
        let chosen = members.filter { selected.contains($0.id) }
        let shown = self.shown(among: members)
        NavigationStack {
            VStack(spacing: 0) {
                JobBarView()
                if selecting { selectionBar(members: members, chosen: chosen) }
                list(members)
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
                        Button("この番組をすべて保護") {
                            model.startBulk(.protecting(true), ids: members.map(\.id))
                        }
                        Button("この番組の保護をすべて解除") {
                            model.startBulk(.protecting(false), ids: members.map(\.id))
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("保護をまとめて変更")
                    .disabled(model.jobRunning || members.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) { SheetCloseButton() }
            }
            .safeAreaInset(edge: .bottom) { if selecting, !chosen.isEmpty { actions(chosen) } }
            .sheet(item: $opened) { TitleSheet(title: $0) }
            .alert(shownTitle(shown, chosen: chosen),
                   isPresented: Binding(get: { shown != nil },
                                        set: { if !$0 { confirmingDelete = false; removing = nil
                                                        failure = nil } }),
                   presenting: shown) { shown in
                switch shown {
                case .bulk:
                    Button("\(chosen.count) 件を削除する", role: .destructive) {
                        model.startBulk(.delete,
                                        ids: chosen.filter { !$0.protected && !$0.recording }.map(\.id))
                        selecting = false
                        selected = []
                    }
                    Button("キャンセル", role: .cancel) {}
                case .one(let title):
                    Button("削除する", role: .destructive) {
                        Task {
                            if await !model.delete(title) {
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
                case .bulk:
                    Text(String(format: "合計 %.1fGB。保護された録画と録画中のものは削除されません。\n"
                                + "レコーダーから削除され、元に戻せません。", Self.gigabytes(chosen)))
                case .one(let title): Text(RecordingsScreen.deleteMessage(title))
                case .failed(let reason): Text(reason)
                }
            }
        }
    }

    private func shownTitle(_ shown: Shown?, chosen: [RecordedTitle]) -> String {
        switch shown {
        case .bulk: "選択した \(chosen.count) 件を削除しますか？"
        case .failed: "エラー"
        case .one, nil: "この録画を削除しますか？"
        }
    }

    private func list(_ members: [RecordedTitle]) -> some View {
        List(members) { title in
            Button {
                if selecting {
                    toggle(title)
                } else {
                    opened = title
                }
            } label: {
                HStack(spacing: 10) {
                    if selecting {
                        Image(systemName: selected.contains(title.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(title.protected ? .secondary : Color.accentColor)
                            .accessibilityHidden(true)
                    }
                    TitleRowView(title: title, channel: model.channelName(for: title),
                                 logo: model.logo(for: title))
                }
                .rowHitArea()
            }
            .buttonStyle(.plain)
            // The tick said to VoiceOver as the row being selected, rather than as the name of a circle.
            .accessibilityAddTraits(selecting && selected.contains(title.id) ? .isSelected : [])
            // Not while picking: a swipe there is how the reader scrolls a list of tick boxes.
            .titleSwipe(selecting ? nil : title, ask: { removing = title.id },
                        unprotect: { Task { await model.setProtected(title, false) } })
        }
        .listStyle(.plain)
    }

    private func selectionBar(members: [RecordedTitle], chosen: [RecordedTitle]) -> some View {
        HStack {
            Button("削除できるものをすべて選択") {
                selected = Set(members.filter { !$0.protected && !$0.recording }.map(\.id))
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

    private func actions(_ chosen: [RecordedTitle]) -> some View {
        VStack(spacing: 8) {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Text(String(format: "選択した %d 件を削除（%.1fGB）", chosen.count, Self.gigabytes(chosen)))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            HStack {
                Button("保護する") { bulkProtect(true, chosen) }
                Button("保護を解除") { bulkProtect(false, chosen) }
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

    private func bulkProtect(_ on: Bool, _ chosen: [RecordedTitle]) {
        model.startBulk(.protecting(on), ids: chosen.map(\.id))
        selecting = false
        selected = []
    }
}
