import RecorderKit
import SwiftUI

/// Time down, channels across, for one broadcast day.
///
/// The same shape as the web app's grid: 132-point columns, an hour ruler down the left, the channel names
/// across the top, a red line at the current time, and a time axis that pinches. Both rulers are drawn over
/// the scrolling content and moved by its offset, which is how they stay put on iOS 17.
struct GuideGridView: View {
    let channels: [Channel]
    let programs: [GuideProgramRow]
    let day: Date
    /// Counts the times the reader has asked to be taken back to now. Watched rather than acted on, so the
    /// grid can answer a second ask.
    let nowRequests: Int
    let reservationFor: (GuideProgramRow) -> Reservation?
    let onSelect: (GuideProgramRow) -> Void

    @AppStorage("gridPointsPerMinute") private var pointsPerMinute = 3.0
    @State private var offset = CGPoint.zero
    @State private var viewport = CGSize.zero
    @State private var pinchStart: Double?
    /// The quarter-hour mark the next scale change has to leave where it is, and where on screen that is.
    @State private var hold: Hold?

    private struct Hold: Equatable {
        var minute: Double
        /// Fraction of the viewport the mark sits at.
        var unit: Double
    }

    private let column = 132.0
    private let gutter = 30.0
    private let header = 54.0
    private let dayMinutes = 1440.0
    private let smallest = 1.5
    private let largest = 8.0
    private let space = "guide-grid"

    /// Channels that have nothing on that day are left out, which drops the sub-channels that only mirror
    /// their parent.
    private var columns: [(channel: Channel, programs: [GuideProgramRow])] {
        let byService = Dictionary(grouping: programs, by: \.serviceID)
        return channels.compactMap { channel in
            guard let programs = byService[channel.serviceID], !programs.isEmpty else { return nil }
            return (channel, programs)
        }
    }

    private var dayStart: Date { GuideStore.dayRange(containing: day).start }
    private var contentWidth: Double { gutter + Double(columns.count) * column }
    private var contentHeight: Double { header + dayMinutes * pointsPerMinute }
    private var nowMinutes: Double { Date().timeIntervalSince(dayStart) / 60 }
    private var showsNow: Bool { (0..<dayMinutes).contains(nowMinutes) }

    var body: some View {
        let columns = columns
        if columns.isEmpty {
            ContentUnavailableView("この日の番組表はありません", systemImage: "squareshape.split.3x3",
                                   description: Text("右上の更新ボタンでレコーダーから取得できます"))
        } else {
            // A GeometryReader, because the rulers are as wide as the whole grid and must not report that
            // width upwards: everything around them would be stretched to it.
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    scroller(columns)
                    hourRuler(height: proxy.size.height)
                    channelRuler(columns, width: proxy.size.width)
                    corner
                    zoomButtons
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .onAppear { viewport = proxy.size }
                .onChange(of: proxy.size) { viewport = $1 }
            }
        }
    }

    // MARK: - the scrolling part

    private func scroller(_ columns: [(channel: Channel, programs: [GuideProgramRow])]) -> some View {
        ScrollViewReader { scroller in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    offsetReader
                    hourLines
                    anchors
                    ForEach(Array(columns.enumerated()), id: \.element.channel.serviceID) { index, entry in
                        if visibleColumns.contains(index) {
                            blocks(entry.programs, atColumn: index)
                        }
                    }
                    if showsNow {
                        Rectangle()
                            .fill(.red)
                            .frame(width: contentWidth, height: 2)
                            .offset(y: header + nowMinutes * pointsPerMinute)
                    }
                }
                .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
            }
            .coordinateSpace(.named(space))
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.02)
                    .onChanged { value in
                        let start = pinchStart ?? pointsPerMinute
                        if pinchStart == nil {
                            pinchStart = start
                            // `startAnchor` is where the fingers went down as a fraction of this view, so
                            // it is the one measurement that does not depend on how far the grid is scrolled
                            hold = holdingTime(atScreenY: value.startAnchor.y * viewport.height, scale: start)
                        }
                        pointsPerMinute = min(largest, max(smallest, start * value.magnification))
                    }
                    .onEnded { _ in pinchStart = nil }
            )
            // After the scale changes, and not inside the gesture: the scroll view has to have been laid
            // out again for `scrollTo` to land on the right place.
            .onChange(of: pointsPerMinute) {
                guard let hold else { return }
                scroller.scrollTo(anchorName(forMinute: hold.minute),
                                  anchor: UnitPoint(x: 0, y: hold.unit))
            }
            // today opens at the current time, another day at the top of the day; the wait is for the
            // content to be laid out, since there is nothing to scroll to before that
            .task(id: dayKey) {
                try? await Task.sleep(for: .milliseconds(120))
                show(minute: showsNow ? nowMinutes : 0, with: scroller)
            }
            // A day that is already today does not change, so the task above does not run again. The wait
            // is for the tab bar's own scroll to the top, which cannot be declined (see GuideScreen).
            .onChange(of: nowRequests) {
                Task {
                    for wait in [0, 120, 300] {
                        try? await Task.sleep(for: .milliseconds(wait))
                        show(minute: showsNow ? nowMinutes : 0, with: scroller)
                    }
                }
            }
        }
    }

    /// Puts a minute of the day at the top of the screen, aiming high enough that the quarter hour before
    /// it clears the channel names drawn over the top.
    private func show(minute: Double, with scroller: ScrollViewProxy) {
        let wanted = max(0, minute - 15 - header / pointsPerMinute)
        withAnimation(.none) {
            scroller.scrollTo(anchorName(forMinute: wanted), anchor: .topLeading)
        }
    }

    /// Where the content sits inside the scroll view. The rulers are moved by this, which is what keeps them
    /// lined up with the part of the grid on screen.
    private var offsetReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.frame(in: .named(space)).origin, initial: true) { _, origin in
                    offset = origin
                }
        }
        .frame(width: 1, height: 1)
    }

    /// Invisible marks every quarter of an hour, so the view can be scrolled to a time. They are stacked
    /// rather than offset because `scrollTo` looks at where a view is laid out, and an offset moves only
    /// what is drawn.
    private var anchors: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 1, height: header)
            ForEach(0..<Int(dayMinutes / 15), id: \.self) { step in
                Color.clear
                    .frame(width: 1, height: 15 * pointsPerMinute)
                    // The mark is a point tall and sits at the top of its quarter hour. `scrollTo(anchor:)`
                    // lines up the same fraction of the target as of the viewport, so a target as tall as a
                    // quarter hour would itself move when the scale changed.
                    .overlay(alignment: .top) {
                        Color.clear.frame(width: 1, height: 1).id(anchorName(forMinute: Double(step) * 15))
                    }
            }
        }
    }

    private var hourLines: some View {
        ForEach(0..<24, id: \.self) { hour in
            Rectangle()
                .fill(Color(.separator).opacity(0.5))
                .frame(width: contentWidth, height: 0.5)
                .offset(y: header + Double(hour) * 60 * pointsPerMinute)
        }
    }

    private func blocks(_ programs: [GuideProgramRow], atColumn index: Int) -> some View {
        ForEach(programs.filter { visibleMinutes.overlaps(minutes(of: $0)) }) { program in
            ProgramBlock(program: program, height: height(of: program), width: column - 2,
                         labelOffset: labelOffset(for: program), reservation: reservationFor(program),
                         onSelect: onSelect)
                .offset(x: gutter + Double(index) * column + 1, y: header + top(of: program))
        }
    }

    // MARK: - the rulers, drawn over the content and moved with it

    private func hourRuler(height: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<24, id: \.self) { index in
                Text("\((index + 4) % 24)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: gutter, alignment: .center)
                    .offset(y: header + Double(index) * 60 * pointsPerMinute + 2)
            }
        }
        .offset(y: offset.y)
        .frame(width: gutter, height: height, alignment: .topLeading)
        .background(Color(.systemBackground))
        .overlay(alignment: .trailing) { Rectangle().fill(Color(.separator)).frame(width: 0.5) }
        .clipped()
    }

    private func channelRuler(_ columns: [(channel: Channel, programs: [GuideProgramRow])],
                              width: Double) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(columns, id: \.channel.serviceID) { entry in
                    VStack(spacing: 2) {
                        if let logo = entry.channel.logo, let image = UIImage(data: logo) {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: 36, height: 18)
                        }
                        Text(entry.channel.name).font(.system(size: 10)).lineLimit(1)
                    }
                    .frame(width: column, height: header)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(.separator)).frame(width: 0.5) }
                }
            }
            .offset(x: gutter + offset.x)
        }
        .frame(width: width, height: header, alignment: .topLeading)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
        .clipped()
    }

    private var corner: some View {
        Color(.secondarySystemBackground)
            .frame(width: gutter, height: header)
    }

    private var zoomButtons: some View {
        HStack(spacing: 8) {
            zoomButton("minus", factor: 1 / 1.4, enabled: pointsPerMinute > smallest)
            zoomButton("plus", factor: 1.4, enabled: pointsPerMinute < largest)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func zoomButton(_ symbol: String, factor: Double, enabled: Bool) -> some View {
        Button {
            hold = holdingTime(atScreenY: viewport.height / 2, scale: pointsPerMinute)
            pointsPerMinute = min(largest, max(smallest, pointsPerMinute * factor))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: - geometry

    private var dayKey: String { "\(Int(dayStart.timeIntervalSince1970))-\(columns.count)" }

    /// What to hold still while the scale changes: the quarter-hour mark nearest a point on screen, and the
    /// fraction of the viewport it is at right now. Without this the grid simply grows downwards from the
    /// start of the day and whatever was under the fingers slides away.
    private func holdingTime(atScreenY screenY: Double, scale: Double) -> Hold? {
        guard viewport.height > 0 else { return nil }
        let minute = (screenY - offset.y - header) / scale
        let quarter = min(max(0, (minute / 15).rounded() * 15), dayMinutes - 15)
        let markY = header + quarter * scale + offset.y
        return Hold(minute: quarter, unit: min(max(0, markY / viewport.height), 1))
    }

    private func anchorName(forMinute minute: Double) -> String {
        "minute-\(Int((minute / 15).rounded(.down)) * 15)"
    }

    private func minutes(of program: GuideProgramRow) -> ClosedRange<Double> {
        let start = program.start.timeIntervalSince(dayStart) / 60
        return start...(start + Double(program.durationSec) / 60)
    }

    private func top(of program: GuideProgramRow) -> Double {
        max(0, program.start.timeIntervalSince(dayStart) / 60) * pointsPerMinute
    }

    private func height(of program: GuideProgramRow) -> Double {
        let start = max(program.start, dayStart)
        let end = min(program.end, dayStart.addingTimeInterval(dayMinutes * 60))
        return max(10, end.timeIntervalSince(start) / 60 * pointsPerMinute - 2)
    }

    /// Keeps a long programme's title in view while its block scrolls past, the way the web grid does.
    private func labelOffset(for program: GuideProgramRow) -> Double {
        let hidden = max(0, -offset.y - top(of: program))
        return min(hidden, max(0, height(of: program) - 34))
    }

    private var visibleMinutes: ClosedRange<Double> {
        let top = (-offset.y - header) / pointsPerMinute
        let visible = max(viewport.height, 1) / pointsPerMinute
        return (top - 60)...(top + visible + 60)
    }

    private var visibleColumns: Range<Int> {
        let first = max(0, Int((-offset.x - gutter) / column) - 1)
        let count = Int(max(viewport.width, 1) / column) + 3
        return first..<min(columns.count, first + count)
    }
}

private struct ProgramBlock: View {
    let program: GuideProgramRow
    let height: Double
    let width: Double
    let labelOffset: Double
    let reservation: Reservation?
    let onSelect: (GuideProgramRow) -> Void

    private var ended: Bool { program.end <= Date() }
    private var onAir: Bool { program.start <= Date() && Date() < program.end }

    /// How much of the programme has gone. Shading that part is what marks the one on air: it meets the red
    /// line at the current time exactly, and says how far in you are.
    private var elapsed: Double {
        guard onAir, program.durationSec > 0 else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(program.start) / Double(program.durationSec)))
    }

    var body: some View {
        Button { onSelect(program) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(Format.time.string(from: program.start))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    + reservationMark
                    + Text(" ")
                    + Text(program.title).font(.system(size: 11, weight: onAir ? .semibold : .regular))
            }
            .multilineTextAlignment(.leading)
            .lineLimit(Int(max(1, (height - labelOffset - 4) / 14)))
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .offset(y: labelOffset)
            .frame(width: width, height: height, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .background(alignment: .top) {
            if onAir {
                genreColor.opacity(0.16).frame(height: height * elapsed)
            }
        }
        .background(reservation == nil ? Color(.secondarySystemGroupedBackground)
                                       : Color.orange.opacity(0.14))
        .overlay(alignment: .leading) { Rectangle().fill(genreColor).frame(width: onAir ? 4 : 3) }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(ended ? 0.5 : 1)
    }

    /// Reservations are marked in the text, because the block is too small for anything else.
    private var reservationMark: Text {
        guard let reservation else { return Text("") }
        return Text(" ") + Text(reservation.recording ? "録画中" : "予約")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(reservation.recording ? .red : .orange)
    }

    /// ARIB level-1 genre to an accent colour, the same mapping the web app uses.
    private var genreColor: Color {
        switch program.genre?.level1 {
        case 0: Color(red: 0.56, green: 0.56, blue: 0.58)
        case 1: Color(red: 0.20, green: 0.78, blue: 0.35)
        case 2: Color(red: 1.00, green: 0.58, blue: 0.00)
        case 3: Color(red: 1.00, green: 0.18, blue: 0.33)
        case 4: Color(red: 0.69, green: 0.32, blue: 0.87)
        case 5: Color(red: 1.00, green: 0.80, blue: 0.00)
        case 6: Color(red: 0.00, green: 0.48, blue: 1.00)
        case 7: Color(red: 0.35, green: 0.78, blue: 0.98)
        case 8: Color(red: 0.19, green: 0.69, blue: 0.78)
        case 9: Color(red: 0.64, green: 0.52, blue: 0.37)
        case 10: Color(red: 0.35, green: 0.34, blue: 0.84)
        case 11: Color(red: 0.00, green: 0.78, blue: 0.75)
        default: Color(.separator)
        }
    }
}
