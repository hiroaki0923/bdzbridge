import RecorderKit
import SwiftUI

struct GuideScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage("guideMode") private var mode = "list"
    @State private var tapped: GuideProgramRow?

    private var grid: Bool { mode == "grid" }

    /// When to ask, after being taken home. The first is as soon as the main actor comes back round, the
    /// rest are there in case the platform's own scroll lands after it.
    private static let homeWaits = [0, 120, 300]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if grid {
                    GuideGridView(channels: model.channels, programs: model.programs, day: model.day,
                                  nowRequests: model.nowRequests,
                                  reservationFor: { model.reservation(for: $0) }) { tapped = $0 }
                    .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
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
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 0) {
                        Button { step(-1) } label: { Image(systemName: "chevron.left") }
                            .disabled(dayIndex <= 0)
                        Menu {
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
                        Button { step(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(dayIndex >= model.days.count - 1)
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
                    .disabled(!model.connected || model.busy != nil)
                }
            }
            .sheet(item: $tapped) { ProgramSheet(program: $0) }
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

    /// The navigation bar has room for a word, not for 地上デジタル.
    private static let shortLabel = ["td": "地デジ", "bs": "BS", "cs": "CS", "bs4k": "BS4K"]

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

    @ViewBuilder
    private var list: some View {
        if let problem = model.problem {
            ContentUnavailableView("エラー", systemImage: "exclamationmark.triangle",
                                   description: Text(problem))
        } else if shown.isEmpty {
            if model.connected {
                ContentUnavailableView("この日の番組表はありません", systemImage: "calendar",
                                       description: Text("右上の更新ボタンでレコーダーから取得できます"))
            } else {
                NoRecorderView(icon: "calendar")
            }
        } else {
            ScrollViewReader { scroller in
                List(shown) { program in
                    Button { tapped = program } label: {
                        ProgramRowView(program: program, logo: logo(for: program.serviceID),
                                       reservation: model.reservation(for: program))
                            .rowHitArea()
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
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

    private func logo(for serviceID: Int) -> Data? {
        model.channels.first { $0.serviceID == serviceID }?.logo
    }

    private func reload() {
        Task { await model.reloadFromCache() }
    }
}

struct ProgramRowView: View {
    let program: GuideProgramRow
    let logo: Data?
    let reservation: Reservation?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.time.string(from: program.start)).font(.callout.monospacedDigit())
                Text(Format.duration(program.durationSec)).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 52, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(program.title).font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    if let logo, let image = UIImage(data: logo) {
                        Image(uiImage: image).resizable().scaledToFit().frame(height: 12)
                    }
                    Text(program.serviceName).font(.caption2).foregroundStyle(.secondary)
                    if let reservation {
                        Text(reservation.recording ? "録画中" : "予約")
                            .font(.caption2)
                            .foregroundStyle(reservation.recording ? .red : .orange)
                    }
                    if let genre = program.genre?.label {
                        Text(genre).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if !program.summary.isEmpty {
                    Text(program.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
