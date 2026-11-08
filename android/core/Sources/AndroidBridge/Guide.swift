import Foundation
import RecBridgeModel
import RecorderKit

/// The guide's screen as the iOS app's list shows it (`GuideScreen`): one broadcasting type and one broadcast day,
/// every station or one, from the cache, with what it says in place of the programmes when there are none.
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
    /// The station the list is narrowed to, or the broadcasting type.
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
    public var programmes: [GuideRow]
    /// Counts the asks to go back to what is on now (`AppModel.goToNow`), which the list answers by scrolling there.
    public var nowRequests: Int64
    /// Whether 番組表を更新 is live (`AppModel.canRefreshGuideByHand`).
    public var canRefresh: Bool
    public var demo: Bool
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
    /// `予約` or `録画中` for a reservation the recorder or the television holds, `送信待ち` for one waiting on this
    /// device to be sent, or nothing; `markIsRed` for one recording now, or a waiting one the device refused.
    public var mark: String
    public var markIsRed: Bool
    public var genre: String
    public var summary: String
    public var starts: Int64
    public var ends: Int64
}

/// What a programme's sheet says of it, before its reservation part (`ProgramSheet`).
public struct ProgrammeSheet: Sendable {
    public var title: String
    public var station: String
    /// `11/8(日) 21:00`.
    public var starts: String
    public var length: String
    public var genre: String
    public var summary: String
    public var extended: String
}

public final class GuideWindow: Sendable {
    let model: AppModel
    private let shown: Watched<GuideScreen>

    init(_ model: AppModel) {
        self.model = model
        shown = Watched { GuideWindow.screen(model) }
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

    /// 番組表を更新: every type, from the device the guide comes from. What there is to say of it, or nothing.
    public func refreshByHand() async -> String {
        await model.refreshGuideByHandFromSource()?.asABody ?? ""
    }

    /// The sheet of the programme whose row has `id`, while the day on screen has it.
    public func programme(_ id: String) async -> ProgrammeSheet? {
        await MainActor.run {
            model.programs.first { $0.id == id }.map { program in
                ProgrammeSheet(title: program.title, station: program.serviceName,
                               starts: Format.dateTime.string(from: program.start),
                               length: Format.duration(program.durationSec), genre: program.genre?.label ?? "",
                               summary: program.summary, extended: program.extended)
            }
        }
    }

    @MainActor
    private static func screen(_ model: AppModel) -> GuideScreen {
        let narrowed = model.serviceFilter != nil
        let shows = model.guideShows(grid: false)
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
        case .noRecorder, .programmes:
            break
        }
        let channel = model.serviceFilter.flatMap { id in model.channels.first { $0.serviceID == id } }
        let type = model.broadcasting
        return GuideScreen(
            shows: "\(shows)", noRecorder: NoRecorder(model), said: said, offers: offers,
            heading: channel?.name ?? Codes.broadcastingShortLabel[type] ?? Codes.broadcastingLabel[type] ?? "番組表",
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
            programmes: model.filteredPrograms.map { row($0, model) },
            nowRequests: Int64(model.nowRequests), canRefresh: model.canRefreshGuideByHand, demo: model.demo)
    }

    @MainActor
    private static func row(_ program: GuideProgramRow, _ model: AppModel) -> GuideRow {
        var mark = "", red = false
        if let reservation = model.reservation(for: program) {
            mark = reservation.recording ? "録画中" : "予約"
            red = reservation.recording
        } else if let waiting = model.pending(for: program) {
            mark = "送信待ち"
            red = waiting.problem != nil
        }
        return GuideRow(id: program.id, serviceID: Int64(program.serviceID), time: Format.time.string(from: program.start),
                        length: Format.duration(program.durationSec), title: program.title,
                        station: program.serviceName, mark: mark, markIsRed: red, genre: program.genre?.label ?? "",
                        summary: program.summary, starts: seconds(program.start), ends: seconds(program.end))
    }
}
