import RecBridgeModel
import RecorderKit
import SwiftUI

/// What the recorder has on its disks and the television on its own: a flat list, or the same recordings gathered
/// into programmes.
struct RecordingsScreen: View {
    @Environment(AppModel.self) private var model
    // A launch argument for this key pins it for the whole run: the argument domain outranks what is
    // written here, so a pick would appear to do nothing. See app/README.md.
    @AppStorage(DefaultsKey.recordingsMode) private var mode = "list"
    @State private var opened: RecordedTitle?
    @State private var welcoming = false
    @State private var openedGroup: TitleGroup?
    /// What is swiped and asked on this screen, and what it says under its title: the model's (`RecordingsState`).
    @State private var state: RecordingsState

    init(model: AppModel) {
        _state = State(initialValue: RecordingsState(model: model))
    }

    /// The view that is on, as the model names the three.
    private var shownMode: RecordingsState.Mode { RecordingsState.Mode(kept: mode) }
    private var grouped: Bool { shownMode == .groups }
    private var duplicating: Bool { shownMode == .dups }

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
                            Label(RecordingsState.Mode.list.label, systemImage: "list.bullet").tag("list")
                            Label(RecordingsState.Mode.groups.label, systemImage: "rectangle.stack").tag("groups")
                            Label(RecordingsState.Mode.dups.label, systemImage: "square.on.square").tag("dups")
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
                        Text(state.heading).font(.subheadline.weight(.semibold))
                        Text(state.subtitle(in: shownMode)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // Only where there is more than one place to tell apart.
                        if !model.titleDestinations.isEmpty {
                            Picker("録画先", selection: Binding(get: { model.shownDestination },
                                                             set: { model.titleDestination = $0 })) {
                                Text("すべて").tag(String?.none)
                                ForEach(model.titleDestinations, id: \.destination) { place in
                                    Text(place.label).tag(String?.some(place.destination))
                                }
                            }
                        }
                        Picker("ジャンル", selection: Binding(get: { model.titleGenre },
                                                            set: { model.titleGenre = $0 })) {
                            Text("すべて \(model.titlesOnTheShownDisk.count)").tag(Int?.none)
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
                        Image(systemName: state.filtering ? "line.3.horizontal.decrease.circle.fill"
                                                          : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(model.titleDestinations.isEmpty ? "ジャンル・並び順・視聴状態で絞り込む"
                                                                        : "録画先・ジャンル・並び順・視聴状態で絞り込む")
                }
            }
            // Keyed on `connected`, and on what the load itself checks, as the keyword conditions' screen is.
            // `connected` turns true partway through a connect, while the recorder is still marked silent
            // from before, and a load set going by it alone finds nothing to ask and is not tried again.
            .task(id: model.connected && !model.offline) { await model.loadTitles() }
            // The television's beside them, at each opening and each time it is attached: neither waits on the
            // other, and what becomes of the television is no reason to ask the recorder again.
            .task(id: model.tvTitlesToRead) { await model.loadTVTitles() }
            // Its list, come back empty over a disk that holds something, read again while the tab is open.
            .task(id: model.tvTitlesToWaitFor) { await model.waitForTVTitles() }
            // The disk in the slot has changed since the list was read, or could not be read into it: the
            // recordings of a disk that has gone leave the list, and an open sheet of one closes with its row.
            .task(id: model.titlesOutOfStep) { await model.loadOutdatedTitles() }
            // Pulling down reads the list again from both devices, though not while a bulk job is walking it.
            // With nothing that can be written to a device, it is the reader asking for another go, as the
            // strip's 再接続 is.
            .refreshable { await model.pullDownTitles() }
            .sheet(item: $opened) { TitleSheet(title: $0, model: model) }
            .sheet(item: $openedGroup) { GroupSheet(group: $0, model: model) }
            // The recording picked for deletion is the last recorder's when its lists are let go of: see
            // `timesForgotten`. The sheets close themselves. A television's rows go with its host, and a row of
            // the other device's stays picked.
            .onChange(of: model.timesForgotten) { state.recordersListsLetGo() }
            .onChange(of: model.tvTimesForgotten) { state.televisionsListsLetGo() }
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
        .welcomesHere($welcoming)
    }

    @ViewBuilder
    private var content: some View {
        if model.recordingsHaveNoRecorder {
            NoRecorderView(icon: "play.rectangle", welcoming: $welcoming)
        } else if model.recordingsAreLoading {
            ContentUnavailableView {
                Label(AppModel.loadingRecordings.title, systemImage: "play.rectangle")
            } description: {
                Text(AppModel.loadingRecordings.detail ?? "")
            }
        } else if duplicating {
            DuplicatesView(model: model) { opened = $0 }
        } else if grouped {
            // Once for the list and its overlay: each read filters, sorts and groups every recording.
            let groups = model.titleGroups
            List(groups) { group in
                Button { openedGroup = group } label: { GroupRowView(group: group).rowHitArea() }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay { if groups.isEmpty { noTitles } }
            .safeAreaInset(edge: .bottom) { noteOfTheTelevision }
        } else {
            let listed = model.shownTitles
            List(listed) { title in
                Button { opened = title } label: {
                    TitleRowView(title: title, channel: model.channelName(for: title),
                                 logo: model.logo(for: title), disk: model.diskShown(title)).rowHitArea()
                }
                .buttonStyle(.plain)
                .titleSwipe(model.swipe(for: title), held: state.holds(title),
                            ask: { state.delete(title) }, unprotect: { state.unprotect(title) })
            }
            .listStyle(.plain)
            .overlay { if listed.isEmpty { noTitles } }
            .safeAreaInset(edge: .bottom) { noteOfTheTelevision }
        }
    }

    /// What an empty list says: that there is nothing, or, while a television's list may still be coming, that it
    /// is on its way.
    @ViewBuilder
    private var noTitles: some View {
        let says = model.noRecordingsSays
        if let detail = says.detail {
            ContentUnavailableView {
                Label(says.title, systemImage: "play.rectangle")
            } description: {
                Text(detail)
            }
        } else {
            ContentUnavailableView(says.title, systemImage: "play.rectangle")
        }
    }

    /// Under the list, once whatever the rows: there is more on the television's disk than the list holds.
    @ViewBuilder
    private var noteOfTheTelevision: some View {
        if let note = model.tvTitlesNote {
            Text(note.asABody)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.regularMaterial)
        }
    }
}

extension View {
    /// The trailing swipe on a recording. It asks before deleting -- this is the recorder's disk and there
    /// is no undo -- so a full swipe is off: a flick should not be able to spend a recording.
    ///
    /// What it offers is the model's to say (`AppModel.swipe(for:)`, handed in as `offer`): the delete where the
    /// delete's own door would let it through, 保護解除 for a protected recording, which has to happen first, and
    /// nothing where the row should not be swipeable at all. Both are held while the device that holds the row
    /// works or a run is under way (`held`), and on a programme's sheet while its own request is out.
    func titleSwipe(_ offer: AppModel.TitleSwipe?, held: Bool, ask: @escaping () -> Void,
                    unprotect: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            switch offer {
            case .delete:
                Button("削除") { ask() }.tint(.red).disabled(held)
            case .unprotect:
                // `role: .destructive` would animate the row away as it is swiped, before there is an
                // answer, and it stays away when the answer is no. The colour is all that is wanted.
                Button("保護解除") { unprotect() }.tint(Color.legibleOrange).disabled(held)
            case nil:
                EmptyView()
            }
        }
    }
}

struct TitleRowView: View {
    let title: RecordedTitle
    let channel: String
    let logo: Data?
    /// The disk it is on, said after when: only off the internal disk (`AppModel.diskShown`), so that nothing
    /// changes in a home with no USB disk.
    var disk: String? = nil

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

    /// The title after the lock and 録画中, in one text for the same reason as the line under it.
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
        if let disk { parts.append(Text(disk)) }
        // No space held for a missing logo, unlike the reservations: this one sits in the middle of the line,
        // where a held gap would read as something having gone wrong.
        if let logo = InlineLogo.text(logo, height: logoHeight) {
            parts.append(channel.isEmpty ? logo : logo + Text.rowGap + Text(channel))
        } else if !channel.isEmpty {
            parts.append(Text(channel))
        }
        if title.lengthKnown { parts.append(Text(Format.duration(title.durationSec))) }
        if let size = Format.size(of: title) { parts.append(Text(size)) }
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
            Text(group.span)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .rowLinesInFull()
        .padding(.vertical, 2)
    }

    /// How many, how big, and how many are new or protected, as one line of text that wraps as a line does.
    private var counts: Text {
        var line = Text(group.countSaid) + Text.rowGap + Text(group.sizeSaid)
        if let new = group.newSaid { line = line + Text.rowGap + Text(new).foregroundStyle(Color.accentColor) }
        if let protected = group.protectedSaid { line = line + Text.rowGap + Text(protected) }
        return line
    }
}

/// One programme's recordings, with the selection that bulk work needs. What is ticked, asked and held is the
/// model's (`GroupSheetState`); the sheet lays it out.
struct GroupSheet: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: GroupSheetState

    /// The episode opened, in a sheet over this one, so that closing it comes back to this programme rather
    /// than to the list of programmes.
    @State private var opened: RecordedTitle?

    init(group: TitleGroup, model: AppModel) {
        _sheet = State(initialValue: GroupSheetState(group: group, model: model))
    }

    var body: some View {
        // Read once here and handed to the parts that need them: each read sorts every recording and picks
        // this programme's out of them, and every tick in the selection draws the sheet again.
        let members = sheet.members
        let chosen = sheet.chosen(among: members)
        let asked = sheet.ask(among: members)
        NavigationStack {
            VStack(spacing: 0) {
                JobBarView()
                if sheet.selecting { selectionBar(members: members, chosen: chosen) }
                list(members)
            }
            .navigationTitle(sheet.group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(sheet.selectLabel) { sheet.toggleSelecting() }
                        .disabled(members.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("この番組をすべて保護") { sheet.protectAll(true, members) }
                        Button("この番組の保護をすべて解除") { sheet.protectAll(false, members) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("保護をまとめて変更")
                    .disabled(sheet.holdsProtectingAll(members))
                }
                ToolbarItem(placement: .topBarTrailing) { SheetCloseButton().disabled(sheet.asking) }
            }
            .interactiveDismissDisabled(sheet.asking)
            .safeAreaInset(edge: .bottom) { if sheet.offersActions(on: chosen) { actions(chosen) } }
            .sheet(item: $opened) { TitleSheet(title: $0, model: model) }
            .closesWithItsRecorder()
            .alert(sheet.askTitle(asked, chosen: chosen),
                   isPresented: Binding(get: { asked != nil }, set: { if !$0 { sheet.askClosed() } }),
                   presenting: asked) { asked in
                if let action = sheet.actionLabel(for: asked, chosen: chosen) {
                    Button(action.label, role: action.destructive ? .destructive : nil) {
                        sheet.act(on: asked, chosen: chosen)
                    }
                    .disabled(sheet.holdsTheAction(for: asked, chosen: chosen))
                }
                Button(sheet.closingLabel(for: asked), role: .cancel) {}
            } message: { asked in
                Text(sheet.message(for: asked, chosen: chosen))
            }
        }
    }

    private func list(_ members: [RecordedTitle]) -> some View {
        List(members) { title in
            Button {
                if sheet.selecting {
                    sheet.toggle(title)
                } else {
                    opened = title
                }
            } label: {
                HStack(spacing: 10) {
                    if sheet.selecting {
                        // Grey where a bulk delete would pass the recording over.
                        Image(systemName: sheet.isSelected(title) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(sheet.wouldBeDeleted(title) ? Color.accentColor : .secondary)
                            .accessibilityHidden(true)
                    }
                    TitleRowView(title: title, channel: model.channelName(for: title),
                                 logo: model.logo(for: title), disk: model.diskShown(title))
                }
                .rowHitArea()
            }
            .buttonStyle(.plain)
            // The tick said to VoiceOver as the row being selected, rather than as the name of a circle.
            .accessibilityAddTraits(sheet.selecting && sheet.isSelected(title) ? .isSelected : [])
            .titleSwipe(sheet.swipe(for: title), held: sheet.holds(title),
                        ask: { sheet.delete(title) }, unprotect: { sheet.unprotect(title) })
        }
        .listStyle(.plain)
    }

    private func selectionBar(members: [RecordedTitle], chosen: [RecordedTitle]) -> some View {
        HStack {
            Button("削除できるものをすべて選択") { sheet.selectWhatCanBeDeleted(among: members) }
            Button("選択解除") { sheet.selectNothing() }
            Spacer()
            Text(GroupSheetState.countLine(chosen)).foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private func actions(_ chosen: [RecordedTitle]) -> some View {
        VStack(spacing: 8) {
            Button(role: .destructive) {
                sheet.deleteChosen()
            } label: {
                Text(GroupSheetState.deleteLabel(chosen))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            HStack {
                Button("保護する") { sheet.protect(true, chosen) }
                Button("保護を解除") { sheet.protect(false, chosen) }
            }
            .buttonStyle(.bordered)
        }
        .disabled(sheet.holdsActions(on: chosen))
        .padding(12)
        .background(.regularMaterial)
    }
}
