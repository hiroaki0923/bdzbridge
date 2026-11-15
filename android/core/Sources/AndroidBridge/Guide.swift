import Foundation
import Observation
import RecBridgeModel
import RecorderKit

/// The guide's screen as the iOS app shows it (`GuideScreen`): one broadcasting type and one broadcast day, from the
/// cache, as the list -- every station or one -- or as the grid (`GuideGridView`), with what it says in place of the
/// programmes when there are none.
public struct GuideScreen: Sendable {
    /// `programmes`, or what is shown in their place (`AppModel.guideShows`): `noRecorder`, `fetching` or `empty`.
    public var shows: String
    /// What is said with no recorder to talk to.
    public var noRecorder: NoRecorder
    /// What is said while the guide is on its way, or when it is empty for the day.
    public var said: Said
    /// What an empty guide offers: `arrange` (every station hidden: the stations' settings), `everyStation` (the
    /// list narrowed to a station with nothing that day: back to all of them), or nothing.
    public var offers: String
    /// The station the list is narrowed to, or the broadcasting type (`AppModel.guideHeading`).
    public var heading: String
    public var broadcastings: [Choice]
    public var broadcasting: String
    /// The stations of the type, in the reader's order, hidden ones left out; `station` is the one the list is
    /// narrowed to, -1 for all of them.
    public var stations: [Station]
    public var station: Int64
    /// The days of the guide, `11/8(日)`, and the one shown.
    public var days: [String]
    public var day: Int64
    /// The list's programmes; none while the guide is the grid, whose are in `layout`.
    public var programmes: [GuideRow]
    /// Counts the asks to go back to what is on now (`AppModel.goToNow`), which the list and the grid answer by
    /// scrolling there.
    public var nowRequests: Int64
    /// Whether 番組表を更新 is live (`AppModel.canRefreshGuideByHand`).
    public var canRefresh: Bool
    public var demo: Bool
    /// Whether the guide is shown as the grid, and what the button that switches says (`AppModel.guideModeLabel`).
    public var grid: Bool
    public var modeLabel: String
    public var layout: GridDay
}

public struct Station: Sendable {
    public var serviceID: Int64
    public var name: String
    /// The logo the recorder sent for it, as an image file; empty for a station whose logo the recorder never had.
    public var logo: [UInt8]
}

/// One programme's row, as the iOS list words it (`ProgramRowView`). Whether it is on air or over is the screen's
/// to work out each minute from `starts` and `ends`, as the iOS row does from its clock.
public struct GuideRow: Sendable {
    public var id: String
    /// The station's, whose logo is among the stations'.
    public var serviceID: Int64
    /// `21:00`, Japan time.
    public var time: String
    /// `54分`.
    public var length: String
    public var title: String
    public var station: String
    /// The programme's mark (`GuideMark`): `予約` or `録画中` for a reservation the recorder or the television holds,
    /// `送信待ち` for one waiting on this device to be sent, or nothing; `markIsRed` for one recording now, or a
    /// waiting one the device refused.
    public var mark: String
    public var markIsRed: Bool
    public var genre: String
    public var summary: String
    public var starts: Int64
    public var ends: Int64
}

/// The day as the grid lays it out (`GuideGridDay`), and how finely it is drawn (`GuideGridScale`): what the iOS
/// grid works out of the model, in minutes. Points, scrolling and colours are the screen's. The columns are there
/// only while the grid shows programmes.
public struct GridDay: Sendable {
    /// The stations with a programme that day, in the reader's order.
    public var columns: [GridColumn]
    /// What a grid opened again for the same day and the same number of columns does not start over for.
    public var key: String
    /// The day's length, and the lead-in a grid opened at a time leaves above it, in minutes.
    public var minutes: Double
    public var leadIn: Double
    /// The minute the grid opens at, and the minute it is now, -1 when now is outside the day: both at the minute
    /// the screen was made, which it is again as each minute turns while the grid is shown.
    public var opening: Double
    public var now: Double
    /// The numbers beside the day's hours, from four.
    public var hours: [String]
    /// The scale the reader left the grid at, in points a minute (dp on Android), and the bounds a pinch is held to;
    /// whether each zoom button does anything, and what the two are called.
    public var scale: Double
    public var smallest: Double
    public var largest: Double
    public var canShrink: Bool
    public var canGrow: Bool
    public var growLabel: String
    public var shrinkLabel: String
}

public struct GridColumn: Sendable {
    public var serviceID: Int64
    public var name: String
    /// Its programmes, in the day's order.
    public var blocks: [GridBlock]
}

/// A programme's block, as the iOS grid draws it (`ProgramBlock`).
public struct GridBlock: Sendable {
    /// What the list's row says of it, of which the block shows the time, the mark and the title, and which the
    /// sheet opens with.
    public var row: GuideRow
    /// Where it starts in the day and how long it is inside the day, in minutes (`GuideGridDay.top`, `shown`).
    public var top: Double
    public var length: Double
    /// Its genre's accent (`GuideGenre.accent`) as 0xRRGGBB, or -1 for a genre with none.
    public var accent: Int64
    /// On the air, over, and how much of it has gone, at the minute the screen was made.
    public var onAir: Bool
    public var ended: Bool
    public var elapsed: Double
    /// What a screen reader says of it (`GuideProgramRow.spoken`).
    public var spoken: String
    /// A reservation the recorder or the television holds for it, and one waiting on this device: the block is
    /// tinted for either, more faintly for the second.
    public var held: Bool
    public var waiting: Bool
}

/// How the reader left the guide, kept where the iOS screens keep it, under their keys in the model's settings, which
/// are touched on the main actor alone: the list or the grid (`DefaultsKey.guideMode`, kept by `GuideScreen`), and the
/// grid's scale (`DefaultsKey.gridPointsPerMinute`, kept by `GuideGridView`); and here for the screen to be told when
/// they change.
@MainActor @Observable
final class GuideChoices {
    /// What the iOS screen writes under `DefaultsKey.guideMode`.
    private static let gridMode = "grid"
    private static let listMode = "list"
    @ObservationIgnored let defaults: WrittenDefaults
    private(set) var grid: Bool
    private(set) var scale: Double

    init(_ defaults: WrittenDefaults) {
        self.defaults = defaults
        grid = defaults.string(forKey: DefaultsKey.guideMode) == Self.gridMode
        // As `@AppStorage` reads it: what was written, or the standard when nothing was.
        scale = defaults.object(forKey: DefaultsKey.gridPointsPerMinute) == nil
            ? GuideGridScale.standard : defaults.double(forKey: DefaultsKey.gridPointsPerMinute)
    }

    func show(grid: Bool) {
        defaults.set(grid ? Self.gridMode : Self.listMode, forKey: DefaultsKey.guideMode)
        self.grid = grid
    }

    /// Held to the scale's bounds, as the iOS grid holds what it keeps.
    func keep(_ scale: Double) {
        let held = GuideGridScale.clamped(scale)
        defaults.set(held, forKey: DefaultsKey.gridPointsPerMinute)
        self.scale = held
    }
}

/// The minute it is, turning over as each minute does for as long as the app runs: what the grid's line at now and
/// what is on the air are worked out at. The iOS grid works them out as it is drawn; here the screen is made again as
/// the minute turns, which is what tells Kotlin -- and only while the grid is shown, as only then is it read.
@MainActor @Observable
final class MinuteClock {
    private(set) var now = Date()

    init() {
        Task { [weak self] in
            while true {
                let date = Date()
                let next = ((date.timeIntervalSince1970 / 60).rounded(.down) + 1) * 60
                try? await Task.sleep(for: .seconds(next - date.timeIntervalSince1970))
                guard let self else { return }
                now = Date()
            }
        }
    }
}

public final class GuideWindow: Sendable {
    let model: AppModel
    let choices: GuideChoices
    private let shown: Watched<GuideScreen>

    init(_ model: AppModel, choices: GuideChoices, clock: MinuteClock) {
        self.model = model
        self.choices = choices
        shown = Watched { GuideWindow.screen(model, choices, clock) }
    }

    public func read() async -> GuideScreen { await shown.read() }
    public func observe(_ listener: some ScreenListener) { shown.watch(listener) }

    public func chooseBroadcasting(_ broadcasting: String) async {
        await MainActor.run { model.broadcasting = broadcasting }
        await model.reloadFromCache()
    }

    /// Narrows the list to one station, or with -1 shows all of them again.
    public func chooseStation(_ serviceID: Int64) async {
        await MainActor.run { model.serviceFilter = serviceID < 0 ? nil : Int(serviceID) }
    }

    /// The day at `index` of `days`.
    public func chooseDay(_ index: Int64) async {
        let chosen = await MainActor.run { () -> Bool in
            guard model.days.indices.contains(Int(index)) else { return false }
            model.day = model.days[Int(index)]
            return true
        }
        if chosen { await model.reloadFromCache() }
    }

    /// Back to what is on now: today, scrolled to it.
    public func goToNow() async {
        await model.goToNow()
    }

    /// The list, or the grid: kept, as the iOS screen keeps it.
    public func showAs(grid: Bool) async {
        await MainActor.run { choices.show(grid: grid) }
    }

    /// The scale a pinch ended at, in points a minute: kept, held to its bounds. Told once the fingers have left the
    /// grid, never as they move.
    public func keepScale(_ scale: Double) async {
        await MainActor.run { choices.keep(scale) }
    }

    /// A zoom button: the scale kept a step larger (`growing`) or smaller, held to its bounds.
    public func zoom(growing: Bool) async {
        await MainActor.run {
            choices.keep(choices.scale * (growing ? GuideGridScale.step : 1 / GuideGridScale.step))
        }
    }

    /// 番組表を更新: every type, from the device the guide comes from. What there is to say of it, or nothing.
    public func refreshByHand() async -> String {
        await model.refreshGuideByHandFromSource()?.asABody ?? ""
    }

    /// The sheet of the programme whose row has `id`, while the day on screen has it: a window of its own, ended
    /// as the sheet closes (`ProgrammeSheetWindow.closed`).
    public func open(_ id: String) async -> ProgrammeSheetWindow? {
        await MainActor.run {
            model.programs.first { $0.id == id }.map {
                ProgrammeSheetWindow(ProgramSheetState(program: $0, model: model), model: model)
            }
        }
    }

    @MainActor
    private static func screen(_ model: AppModel, _ choices: GuideChoices, _ clock: MinuteClock) -> GuideScreen {
        let grid = choices.grid
        // The grid shows every station, whatever the list is narrowed to.
        let narrowed = !grid && model.serviceFilter != nil
        let shows = model.guideShows(grid: grid)
        let day = grid && shows == .programmes
            ? GuideGridDay(channels: model.channels, programs: model.programs, day: model.day) : nil
        // Programmes none of whose stations has a column: said as the iOS grid says it, with no way out offered.
        let emptyGrid = day?.columns.isEmpty == true
        var said = Said("")
        var offers = ""
        switch shows {
        case .fetching:
            said = Said(AppModel.fetchingTheGuide)
        case .empty:
            let empty = model.guideEmpty(narrowed: narrowed)
            said = Said(model.says(empty))
            if empty == .everyChannelHidden { offers = "arrange" }
            if empty == .narrowedToNothing { offers = "everyStation" }
        case .programmes where emptyGrid:
            said = Said(model.says(model.guideEmpty(narrowed: false)))
        case .noRecorder, .programmes:
            break
        }
        let type = model.broadcasting
        return GuideScreen(
            shows: emptyGrid ? "empty" : "\(shows)", noRecorder: NoRecorder(model), said: said, offers: offers,
            heading: model.guideHeading(grid: grid),
            broadcastings: GuideRefresh.offeredTypes(model.counts).map {
                Choice(code: $0, label: Codes.broadcastingLabel[$0] ?? $0)
            },
            broadcasting: type,
            stations: model.channels.map {
                Station(serviceID: Int64($0.serviceID), name: $0.name, logo: $0.logo.map { [UInt8]($0) } ?? [])
            },
            station: Int64(model.serviceFilter ?? -1),
            days: model.days.map { Format.day.string(from: $0) },
            day: Int64(model.days.firstIndex { Calendar.current.isDate($0, inSameDayAs: model.day) } ?? 0),
            programmes: grid ? [] : model.filteredPrograms.map { row($0, model) },
            nowRequests: Int64(model.nowRequests), canRefresh: model.canRefreshGuideByHand, demo: model.demo,
            grid: grid, modeLabel: AppModel.guideModeLabel(grid: grid),
            layout: layout(emptyGrid ? nil : day, model, choices, clock))
    }

    @MainActor
    private static func layout(_ day: GuideGridDay?, _ model: AppModel, _ choices: GuideChoices,
                               _ clock: MinuteClock) -> GridDay {
        let scale = choices.scale
        var layout = GridDay(
            columns: [], key: "", minutes: GuideGridDay.minutes, leadIn: GuideGridDay.leadIn, opening: 0, now: -1,
            hours: (0..<Int(GuideGridDay.minutes / 60)).map { "\(GuideGridDay.hourLabel($0))" },
            scale: scale, smallest: GuideGridScale.smallest, largest: GuideGridScale.largest,
            canShrink: GuideGridScale.canShrink(scale), canGrow: GuideGridScale.canGrow(scale),
            growLabel: GuideGridScale.growLabel, shrinkLabel: GuideGridScale.shrinkLabel)
        guard let day else { return layout }
        // Read only for a grid with columns, so that the list is not made again each minute.
        let now = clock.now
        layout.key = day.key
        layout.opening = day.openingMinute(pinned: choices.defaults.string(forKey: DefaultsKey.guideOpenAt) ?? "",
                                           now: now)
        layout.now = day.nowMinute(at: now) ?? -1
        layout.columns = day.columns.map { column in
            GridColumn(serviceID: Int64(column.channel.serviceID), name: column.channel.name,
                       blocks: column.programs.map { block($0, day, model, at: now) })
        }
        return layout
    }

    @MainActor
    private static func block(_ program: GuideProgramRow, _ day: GuideGridDay, _ model: AppModel,
                              at now: Date) -> GridBlock {
        let reservation = model.reservation(for: program)
        let pending = model.pending(for: program)
        let mark = GuideMark(reservation: reservation, pending: pending)
        return GridBlock(
            row: row(program, marked: mark), top: day.top(of: program), length: day.shown(of: program),
            accent: packed(GuideGenre.accent(level1: program.genre?.level1)), onAir: program.isOnAir(at: now),
            ended: program.hasEnded(at: now), elapsed: program.elapsed(at: now),
            spoken: program.spoken(mark: mark, at: now), held: reservation != nil, waiting: pending != nil)
    }

    /// An accent's fractions as 0xRRGGBB, which is how Android writes a colour: each to the nearest of its 256 steps,
    /// as Compose rounds a colour made of fractions.
    private static func packed(_ accent: GuideGenre.Accent?) -> Int64 {
        guard let accent else { return -1 }
        func step(_ fraction: Double) -> Int64 { Int64((fraction * 255).rounded()) }
        return step(accent.red) << 16 | step(accent.green) << 8 | step(accent.blue)
    }

    @MainActor
    static func row(_ program: GuideProgramRow, _ model: AppModel) -> GuideRow {
        row(program, marked: GuideMark(reservation: model.reservation(for: program),
                                       pending: model.pending(for: program)))
    }

    @MainActor
    private static func row(_ program: GuideProgramRow, marked mark: GuideMark?) -> GuideRow {
        GuideRow(id: program.id, serviceID: Int64(program.serviceID), time: Format.time.string(from: program.start),
                 length: Format.duration(program.durationSec), title: program.title, station: program.serviceName,
                 mark: mark?.word ?? "", markIsRed: mark?.isRed ?? false, genre: program.genre?.label ?? "",
                 summary: program.summary, starts: seconds(program.start), ends: seconds(program.end))
    }
}
