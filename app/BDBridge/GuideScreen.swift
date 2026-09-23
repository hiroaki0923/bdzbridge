import RecorderKit
import SwiftUI

struct GuideScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DefaultsKey.guideMode) private var mode = "list"
    /// The time of day the guide should open at instead of now, as `HH:mm`. Nothing in the app writes it;
    /// the store screenshots pass it on the command line. See `GuideClock`.
    @AppStorage(DefaultsKey.guideOpenAt) private var openAt = ""
    @State private var tapped: GuideProgramRow?
    @State private var arranging = false

    private var grid: Bool { mode == "grid" }

    /// When to ask, after being taken home. The first is as soon as the main actor comes back round, the
    /// rest are there in case the platform's own scroll lands after it.
    private static let homeWaits = [0, 120, 300]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if nothingAndNoRecorder {
                    NoRecorderView(icon: "calendar")
                } else if nothing, !nothingByChoice, model.guideOnItsWay {
                    // The first run lands here as soon as the recorder answers. Saying there was nothing for the
                    // day, and pointing at a refresh button greyed out meanwhile, read as though the download
                    // had come to nothing.
                    ContentUnavailableView {
                        Label("番組表を取得しています", systemImage: "calendar")
                    } description: {
                        Text("初回は少し時間がかかります")
                    } actions: {
                        ProgressView()
                    }
                } else if nothing {
                    GuideEmptyView(narrowed: narrowed) { arranging = true }
                } else if grid {
                    GuideGridView(channels: model.channels, programs: model.programs, day: model.day,
                                  nowRequests: model.nowRequests,
                                  reservationFor: { model.reservation(for: $0) },
                                  pendingFor: { model.pending(for: $0) }) { tapped = $0 }
                    .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
            .recorderActivity()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // what the screen is showing: the broadcasting type and the channel on the left, the day in
                // the middle with a step either side. Nothing needs a row of its own.
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("放送", selection: broadcastingChoice) {
                            ForEach(["td", "bs", "cs", "bs4k"], id: \.self) { broadcasting in
                                Text(Codes.broadcastingLabel[broadcasting] ?? broadcasting).tag(broadcasting)
                            }
                        }
                        // Above the channels rather than after them, where a type with sixty would leave it
                        // at the foot of a long scroll. In the grid as well, whose columns come in this order.
                        Button { arranging = true } label: {
                            Label("チャンネルの表示と並び順", systemImage: "arrow.up.arrow.down")
                        }
                        if !grid {
                            Picker("局", selection: channelChoice) {
                                Text("すべての局").tag(-1)
                                ForEach(model.channels) { channel in
                                    Text(channel.name).tag(channel.serviceID)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(heading).font(.subheadline.weight(.semibold)).lineLimit(1)
                            // Only a sign that this opens a menu, which VoiceOver says of it anyway.
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 0) {
                        Button { step(-1) } label: { dayArrow("chevron.left") }
                            .disabled(dayIndex <= 0)
                            .accessibilityLabel("前の日")
                        Menu {
                            // Where a tap on the guide's tab already showing goes, which few would guess. It
                            // was the only way back to what is on now.
                            Button { model.goToNow() } label: { Label("今", systemImage: "clock") }
                            Divider()
                            Picker("日付", selection: dayChoice) {
                                ForEach(model.days, id: \.self) { day in
                                    Text(Format.day.string(from: day)).tag(day)
                                }
                            }
                        } label: {
                            Text(Format.day.string(from: model.day))
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .frame(minWidth: 92)
                        }
                        Button { step(1) } label: { dayArrow("chevron.right") }
                            .disabled(dayIndex >= model.days.count - 1)
                            .accessibilityLabel("次の日")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        mode = grid ? "list" : "grid"
                    } label: {
                        Image(systemName: grid ? "tablecells" : "list.bullet")
                    }
                    .accessibilityLabel(grid ? "リスト表示にする" : "表形式で表示")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshGuide() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("番組表を更新")
                    // Not for a model that has no guide to give, which the empty guide says in so many words:
                    // a button left alive beside that looked like the way to put it right.
                    .disabled(!model.connected || model.busy != nil || model.info?.epgCapable == false)
                }
            }
            .sheet(item: $tapped) { ProgramSheet(program: $0) }
            .sheet(isPresented: $arranging) { ChannelsSheet(broadcasting: model.broadcasting) }
        }
    }

    /// What the title says: the channel when one is picked, otherwise the broadcasting type.
    private var heading: String {
        if !grid, let serviceID = model.serviceFilter,
           let channel = model.channels.first(where: { $0.serviceID == serviceID }) {
            return channel.name
        }
        return Self.shortLabel[model.broadcasting] ?? Codes.broadcastingLabel[model.broadcasting] ?? "番組表"
    }

    /// The navigation bar has room for a word, not for 地上デジタル. Nor has a segmented control.
    static let shortLabel = ["td": "地デジ", "bs": "BS", "cs": "CS", "bs4k": "BS4K"]

    /// An arrow beside the day, which was a glyph and answered only to a tap on the glyph. Its area runs up
    /// and down as far towards the 44 points a finger needs as the bar lets an item be tall, which takes
    /// nothing from anything beside it. Not across: on a narrow iPhone the arrows already all but touch the
    /// buttons on the right. Nor can the area reach past the arrow instead, as the strip's buttons do: the bar
    /// answers only to taps inside what its items take up.
    private func dayArrow(_ symbol: String) -> some View {
        Image(systemName: symbol).frame(minHeight: 44).contentShape(Rectangle())
    }

    private var dayIndex: Int {
        model.days.firstIndex { Calendar.current.isDate($0, inSameDayAs: model.day) } ?? 0
    }

    private func step(_ by: Int) {
        let next = dayIndex + by
        guard model.days.indices.contains(next) else { return }
        model.day = model.days[next]
        reload()
    }

    private var dayChoice: Binding<Date> {
        Binding(get: { model.day }, set: { model.day = $0; reload() })
    }

    private var broadcastingChoice: Binding<String> {
        Binding(get: { model.broadcasting }, set: { model.broadcasting = $0; reload() })
    }

    private var channelChoice: Binding<Int> {
        Binding(get: { model.serviceFilter ?? -1 },
                set: { model.serviceFilter = $0 < 0 ? nil : $0 })
    }

    /// What is on at this minute, or the next thing if nothing is. `shown` is in start order, so the first
    /// programme that has not ended is it.
    private var onAirOrNext: GuideProgramRow? {
        let now = Date()
        return shown.first { $0.end > now }
    }

    /// Nothing for the day on screen, and no recorder to fetch it from. The list said エラー over whatever had
    /// failed last, with no button under it and nothing to do but find the settings, and the grid pointed to
    /// the refresh button, which is greyed out while not connected. `NoRecorderView` says what is wrong and
    /// offers 再接続 and レコーダーを探す.
    private var nothingAndNoRecorder: Bool {
        !model.connected && nothing && !nothingByChoice
    }

    /// Nothing for the day on screen. The grid shows every channel whatever the list is narrowed to, so it is
    /// judged by all of the day's programmes.
    private var nothing: Bool {
        (grid ? model.programs : shown).isEmpty
    }

    /// Whether the list is narrowed to one channel. The grid is not, whatever the list is set to.
    private var narrowed: Bool { !grid && model.serviceFilter != nil }

    /// Nothing on screen because of what the reader chose rather than what the cache holds: every channel
    /// hidden, or the list narrowed to a channel with nothing that day. Said ahead of anything about the
    /// recorder, which is not the reason and could not put it right.
    private var nothingByChoice: Bool {
        model.everyChannelHidden || (narrowed && !model.programs.isEmpty)
    }

    /// The day's programmes. Only reached with some to show: the empty states are the body's.
    ///
    /// A guide that is in the cache is shown whatever the recorder is doing. It is the whole reason the cache
    /// exists: away from home the recorder cannot be reached, and a programme can still be read and still be
    /// reserved -- the reservation waits in the queue. An error in place of the guide left nothing to do but
    /// go home.
    private var list: some View {
        // Drawn again each minute, so that the programme on air is marked as it starts and the one before it
        // dimmed as it ends, with nobody touching the list.
        TimelineView(.everyMinute) { timeline in
            ScrollViewReader { scroller in
                List(shown) { program in
                    Button { tapped = program } label: {
                        ProgramRowView(program: program, logo: logo(for: program.serviceID),
                                       reservation: model.reservation(for: program),
                                       pending: model.pending(for: program), now: timeline.date)
                            .rowHitArea()
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                // Open where the grid opens: at what is on now. A list of a whole broadcast day starts at
                // four in the morning, and at nine at night that is seventeen hours of scrolling before
                // anything worth reading.
                .task(id: openingKey) {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard let target = opening else { return }
                    withAnimation(.none) { scroller.scrollTo(target.id, anchor: .top) }
                }
                // The tab bar's own answer to a tap on the tab already showing is the top of the list, and
                // there is no declining it: `UIScrollView.scrollsToTop` is honoured for the status bar but
                // not for a tab, and the scroll view here belongs to SwiftUI, so it cannot be replaced with
                // one that ignores the request. So this waits for that scroll to finish and then goes where
                // the reader wanted, without animating: at eleven at night the distance is most of a day,
                // and a snap reads better than a long slide.
                //
                // Timing is a race this end cannot see the other side of, so it is not run once. The first
                // ask arrives before the platform's scroll and may be overridden by it; the later ones
                // land after it and put things right. On a real iPhone the result reads as one movement.
                .onChange(of: model.nowRequests) {
                    Task {
                        for wait in Self.homeWaits {
                            try? await Task.sleep(for: .milliseconds(wait))
                            guard let target = onAirOrNext else { return }
                            withAnimation(.none) { scroller.scrollTo(target.id, anchor: .top) }
                        }
                    }
                }
            }
        }
    }

    private var shown: [GuideProgramRow] { model.filteredPrograms }

    /// Rerun the opening scroll when the day, the broadcasting type or the channel changes -- and when the
    /// programmes themselves arrive, which on a cold start is after the list is already on screen.
    private var openingKey: String {
        "\(model.broadcasting)-\(model.day.timeIntervalSince1970)-\(model.serviceFilter ?? -1)-\(shown.count)"
    }

    /// What to put at the top: what is on now, or, on another day, the first programme of it. A pinned time
    /// wins, which is how the store screenshots land on the evening.
    private var opening: GuideProgramRow? {
        guard let minute = GuideClock.minuteOfBroadcastDay(openAt) else { return onAirOrNext }
        let moment = GuideStore.dayRange(containing: model.day).start.addingTimeInterval(minute * 60)
        return shown.first { $0.end > moment } ?? onAirOrNext
    }

    private func logo(for serviceID: Int) -> Data? {
        model.channels.first { $0.serviceID == serviceID }?.logo
    }

    private func reload() {
        Task { await model.reloadFromCache() }
    }
}

/// What the guide says when there is nothing to show for the day, in the list and in the grid alike. It used
/// to say この日の番組表はありません and point at the refresh button whatever the reason -- in the grid always,
/// in the list unless something had failed -- and most of the reasons are not put right by a refresh: a
/// broadcasting type or a day the demo's guide does not cover, every channel hidden, the list narrowed to a
/// channel with nothing that day, a recorder with no guide to give.
///
/// Not for a recorder that cannot be reached, nor for a guide on its way, which the screen says before this.
struct GuideEmptyView: View {
    @Environment(AppModel.self) private var model
    /// The list narrowed to one channel. The grid shows every channel, whatever the list is set to.
    var narrowed = false
    /// Opens the channel settings, for a guide with every channel hidden. The sheet belongs to the screen
    /// rather than to this view: the first channel turned back on takes this view away, and a sheet hung on
    /// it closed with it, under the reader's finger.
    var arrange: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        let type = Self.inSentence(model.broadcasting)
        let cached = model.counts[model.broadcasting]?.programs ?? 0
        if model.everyChannelHidden {
            ContentUnavailableView {
                Label("\(type)の局をすべて非表示にしています", systemImage: "eye.slash")
            } description: {
                Text("表示する局を選ぶと、番組表に出てきます")
            } actions: {
                if let arrange {
                    Button("チャンネルの表示と並び順", action: arrange)
                }
            }
        } else if narrowed, !model.programs.isEmpty {
            ContentUnavailableView {
                Label("この日の\(model.channelName)の番組はありません", systemImage: "calendar")
            } actions: {
                Button("すべての局を表示") { model.serviceFilter = nil }
            }
        } else if model.demo {
            // The demo's guide is what DemoData invented, and a refresh would fetch the same again.
            ContentUnavailableView(cached == 0 ? "\(type)の番組表はありません" : "この日の番組表はありません",
                                   systemImage: "calendar", description: Text(DemoData.guideCoverage))
        } else if model.info?.epgCapable == false {
            ContentUnavailableView("このレコーダーは番組表に対応していません", systemImage: "calendar",
                                   description: Text("この機種からは番組表を取得できません"))
        } else if let problem = model.problem {
            ContentUnavailableView("エラー", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else if cached == 0, model.counts.values.contains(where: { $0.programs > 0 }) {
            // The other types came in and this one did not: the recorder had no file for it, which is what a
            // model without that kind of tuner answers.
            ContentUnavailableView("\(type)の番組表はありません", systemImage: "calendar",
                                   description: Text("レコーダーが対応していない放送は空のままです。"
                                                     + "右上の更新ボタンで取得し直せます"))
        } else if cached == 0 {
            ContentUnavailableView("番組表をまだ取得していません", systemImage: "calendar",
                                   description: Text("右上の更新ボタンでレコーダーから取得できます"))
        } else {
            ContentUnavailableView("この日の番組表はありません", systemImage: "calendar",
                                   description: Text("右上の更新ボタンでレコーダーから取得できます"))
        }
    }

    /// A broadcasting type's name at the start of a sentence: 地上デジタル as it is, a Latin one set off from the
    /// Japanese after it by a space, as the app writes GB and Wi-Fi.
    static func inSentence(_ broadcasting: String) -> String {
        let label = Codes.broadcastingLabel[broadcasting] ?? broadcasting
        return label.last?.isASCII == true ? label + " " : label
    }
}

struct ProgramRowView: View {
    let program: GuideProgramRow
    let logo: Data?
    let reservation: Reservation?
    /// A reservation for it waiting on this phone for the recorder. Marked as well, since it is as much the
    /// reader's reservation as one the recorder holds; red when the recorder refused it.
    let pending: PendingReservation?
    /// In the search results, for a programme found only in its details: the words found and a little on
    /// either side, since neither the title nor the description says why it is there.
    var snippet: Search.Snippet? = nil
    /// The time the marks are worked out for. The guide's list passes the minute it was last drawn at.
    var now = Date()

    /// The time column, as wide as the time needs at the reader's text size. At a fixed 52 points it split
    /// 18:0 / 0 two sizes above the default.
    @ScaledMetric(relativeTo: .callout) private var timeWidth = 52.0
    @ScaledMetric(relativeTo: .caption2) private var logoHeight = 12.0
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Marked the way the grid marks it, which the list did not: a day's list opens at what is on now, and
    /// nothing said which of the rows at the top that was.
    private var onAir: Bool { program.start <= now && now < program.end }
    /// Dimmed, as in the grid, so that the eye goes past what can no longer be watched or reserved.
    private var ended: Bool { program.end <= now }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // At the accessibility sizes a time column wide enough for the time leaves the title a few
                // characters a line, so the time goes above it instead.
                VStack(alignment: .leading, spacing: 3) {
                    (Text(Format.time.string(from: program.start)).font(.callout.monospacedDigit())
                        + Text.rowGap
                        + Text(Format.duration(program.durationSec)).foregroundStyle(.secondary))
                        .font(.caption2)
                    details
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.time.string(from: program.start)).font(.callout.monospacedDigit())
                        Text(Format.duration(program.durationSec)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: timeWidth, alignment: .trailing)
                    details
                }
            }
        }
        .rowLinesInFull()
        .padding(.vertical, 2)
        .opacity(ended ? 0.5 : 1)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(program.title).font(.subheadline.weight(onAir ? .semibold : .regular)).lineLimit(2)
            meta.font(.caption2).foregroundStyle(.secondary)
            if !program.summary.isEmpty {
                Text(program.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let snippet {
                Text(Self.detail(snippet)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    /// The channel and the marks as one line of text, which wraps as a line does. As separate views side by
    /// side, a large text size gave each a narrow column of its own. The genre is in the secondary grey with
    /// the rest: it was fainter still, too faint to read, and it is the only place the list says it.
    private var meta: Text {
        var line = Text(program.serviceName)
        if onAir {
            line = line + Text.rowGap + Text("放送中").fontWeight(.semibold).foregroundStyle(.tint)
        }
        if let reservation {
            line = line + Text.rowGap + Text(reservation.recording ? "録画中" : "予約")
                .foregroundStyle(reservation.recording ? Color.red : Color.legibleOrange)
        } else if let pending {
            line = line + Text.rowGap + Text("送信待ち")
                .foregroundStyle(pending.problem == nil ? Color.legibleOrange : Color.red)
        }
        if let genre = program.genre?.label {
            line = line + Text.rowGap + Text(genre)
        }
        guard let logo = InlineLogo.text(logo, height: logoHeight) else { return line }
        return logo + Text.rowGap + line
    }

    /// 詳細, as the programme's sheet heads the same text, and the words found set in the colour of the title.
    private static func detail(_ snippet: Search.Snippet) -> AttributedString {
        var found = AttributedString(snippet.match)
        found.foregroundColor = .primary
        found.inlinePresentationIntent = .stronglyEmphasized
        return AttributedString("詳細：" + snippet.before) + found + AttributedString(snippet.after)
    }
}
