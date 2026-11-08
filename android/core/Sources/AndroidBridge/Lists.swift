import Foundation
import RecBridgeModel
import RecorderKit

// The reservations' and the recordings' screens as the iOS app lists them, for reading: their sheets, their
// sorting and narrowing, and pulling down come with the screens' own steps.

/// The reservations' screen (`ReservationsScreen`).
public struct ReservationsScreen: Sendable {
    /// With no recorder to talk to and nothing to show, what is said in place of the list.
    public var hasNoRecorder: Bool
    public var noRecorder: NoRecorder
    /// Nothing listed and nothing waiting: what is said over the list.
    public var isEmpty: Bool
    public var empty: Said
    /// `12 件 · 録画中 1`, under the screen's title.
    public var subtitle: String
    /// The reservations waiting on this device to be sent, with what is said of when they go, then the list by day.
    public var waiting: [WaitingRow]
    public var waitingSays: String
    public var sections: [ReservationSection]
    /// The recorder's line while it works, or what went wrong, in red.
    public var line: String
    public var lineIsAProblem: Bool
    /// What the recorder's list is read again by: when it changes, the screen loads it (`load`), as the iOS screen
    /// does each time the app connects. The television's is read once each time the screen appears (`loadTV`).
    public var loadKey: String
}

public struct ReservationSection: Sendable {
    public var title: String
    public var rows: [ReservationRow]
}

public struct ReservationRow: Sendable {
    public var id: String
    /// `21:00`, `54分`, and what is marked of it: recording now, clashing with another.
    public var time: String
    public var length: String
    public var recording: Bool
    public var conflict: Bool
    /// Made by the recorder's own keyword conditions (おまかせ).
    public var byTheRecorder: Bool
    public var title: String
    /// The device and the disk where they are said, the station, the mode, the repeat and the genre.
    public var details: String
}

public struct WaitingRow: Sendable {
    public var id: String
    public var title: String
    public var details: String
    /// What the device said when it refused it, or nothing.
    public var problem: String
}

public final class ReservationsWindow: Sendable {
    let model: AppModel
    private let shown: Watched<ReservationsScreen>

    init(_ model: AppModel) {
        self.model = model
        shown = Watched { ReservationsWindow.screen(model) }
    }

    public func read() async -> ReservationsScreen { await shown.read() }
    public func observe(_ listener: some ScreenListener) { shown.watch(listener) }

    /// The sheet of the reservation whose row has `id` (`Reservation.listKey`), while the list has it: a window of
    /// its own, ended as the sheet closes (`ReservationSheetWindow.closed`).
    public func open(_ id: String) async -> ReservationSheetWindow? {
        await MainActor.run {
            model.reservation(listKey: id).map {
                ReservationSheetWindow(ReservationSheetState(reservation: $0, model: model), model: model)
            }
        }
    }

    /// The queue on this device, then the recorder's list.
    public func load() async {
        await model.loadPending()
        await model.loadReservations()
    }

    /// The television's list, apart from the recorder's: keyed with it, the recorder would be made sure of, and
    /// woken, whenever the television's state moved (`ReservationsScreen`).
    public func loadTV() async {
        await model.loadReservations(of: .tv)
    }

    @MainActor
    private static func screen(_ model: AppModel) -> ReservationsScreen {
        let shown = model.shownReservations
        var subtitle: [String] = []
        if model.reservationKind != .all { subtitle.append(model.reservationKind.label) }
        subtitle.append("\(shown.count) 件")
        let recording = shown.filter(\.recording).count, clashing = shown.filter(\.conflict).count
        if recording > 0 { subtitle.append("録画中 \(recording)") }
        if clashing > 0 { subtitle.append("重複 \(clashing)") }
        let problem = model.problem(for: .recorder) ?? model.problem(for: .tv)
        return ReservationsScreen(
            hasNoRecorder: model.reservationsHaveNoRecorder, noRecorder: NoRecorder(model),
            isEmpty: model.reservationsAreEmpty, empty: Said(AppModel.noReservations),
            subtitle: subtitle.joined(separator: " · "),
            waiting: model.pending.map { waiting in
                var parts = [model.deviceSaid(for: waiting), model.diskShown(waiting),
                             Format.dateTime.string(from: waiting.request.start), waiting.serviceName].compactMap { $0 }
                if let quality = Codes.quality(code: waiting.request.qualityCode) {
                    parts.append(Codes.qualityLabel[quality] ?? quality)
                }
                if waiting.request.eventID == nil { parts.append("時刻指定") }
                return WaitingRow(id: waiting.id, title: waiting.request.title, details: parts.joined(separator: " · "),
                                  problem: waiting.problem?.asABody ?? "")
            },
            waitingSays: model.whatWaitsSays,
            sections: model.reservationSections.map { section in
                ReservationSection(title: section.title, rows: section.items.map { row($0, model) })
            },
            line: model.busy ?? problem?.asABody ?? "", lineIsAProblem: model.busy == nil && problem != nil,
            loadKey: "\(model.connected && !model.offline)")
    }

    @MainActor
    private static func row(_ reservation: Reservation, _ model: AppModel) -> ReservationRow {
        var parts = [model.tv != nil ? reservation.device.label : nil, model.diskShown(reservation)].compactMap { $0 }
        let channel = model.channelName(for: reservation)
        if !channel.isEmpty { parts.append(channel) }
        if let quality = reservation.qualityName { parts.append(quality) }
        if let name = reservation.repeatName, name != "none" { parts.append(Codes.repeatLabel[name] ?? name) }
        if let genre = reservation.genreCode.flatMap({ Codes.genreLabel[$0 / 16] }) { parts.append(genre) }
        return ReservationRow(id: reservation.listKey, time: Format.time.string(from: reservation.start),
                              length: Format.duration(reservation.durationSec), recording: reservation.recording,
                              conflict: reservation.conflict, byTheRecorder: reservation.createdByRecorder,
                              title: reservation.title, details: parts.joined(separator: " · "))
    }
}

/// The recordings' screen (`RecordingsScreen`), the list of every recording on every disk, newest first.
public struct RecordingsScreen: Sendable {
    public var hasNoRecorder: Bool
    public var noRecorder: NoRecorder
    /// Being read, with none read yet: what is said in place of the list.
    public var isLoading: Bool
    public var loading: Said
    /// Nothing listed: what is said over the list.
    public var empty: Said
    /// `残り 120.5 GB` when the free space is known, `録画` when it is not.
    public var heading: String
    /// The recorder's line while it works, or what is shown: the disk and the genre picked, and how many.
    public var subtitle: String
    /// The filters, as the iOS screen's menu offers them: 録画先 (only where there is more than one place), ジャンル
    /// with how many of each, 並び順 and 視聴状態. An empty code is すべて; `filtering` when any is not its default.
    public var destinations: [Labelled]
    public var destination: String
    public var genres: [Labelled]
    public var genre: String
    public var sorts: [Labelled]
    public var sort: String
    public var states: [Labelled]
    public var state: String
    public var filtering: Bool
    /// More on the television's disk than the list holds, said under it.
    public var tvNote: String
    public var rows: [RecordingRow]
    public var line: String
    public var lineIsAProblem: Bool
    /// What each list is read again by, as on the iOS screen: the recorder's (`load`) each time the app connects,
    /// the television's (`loadTV`) each time it is attached, and the recorder's afresh (`loadOutdated`) when the
    /// disk in the USB slot is no longer the one the list was read from. What becomes of the television is no
    /// reason to ask the recorder again. The wait for a television's list that may still be coming
    /// (`AppModel.waitForTVTitles`), which ends with the screen's task, comes with the television's screens.
    public var loadKey: String
    public var tvKey: String
    public var outdatedKey: String
}

public struct RecordingRow: Sendable {
    public var id: String
    public var title: String
    public var recording: Bool
    public var protected: Bool
    /// When, the disk where it is said, the station, the length, the size and the mode.
    public var details: String
    /// `未視聴`, `視聴済み`, `途中まで`, and `unwatched` for the first, which is in the accent colour.
    public var watched: String
    public var unwatched: Bool
    public var genre: String
}

public final class RecordingsWindow: Sendable {
    let model: AppModel
    private let shown: Watched<RecordingsScreen>

    init(_ model: AppModel) {
        self.model = model
        shown = Watched { RecordingsWindow.screen(model) }
    }

    public func read() async -> RecordingsScreen { await shown.read() }
    public func observe(_ listener: some ScreenListener) { shown.watch(listener) }

    public func load() async {
        await model.loadTitles()
    }

    public func loadTV() async {
        await model.loadTVTitles()
    }

    public func loadOutdated() async {
        await model.loadOutdatedTitles()
    }

    /// Pulled down: the list read again from both devices, though not while a bulk job is walking it.
    public func pullDown() async {
        await model.pullDownTitles()
    }

    public func chooseDestination(_ code: String) async {
        await MainActor.run { model.titleDestination = code.isEmpty ? nil : code }
    }

    public func chooseGenre(_ code: String) async {
        await MainActor.run { model.titleGenre = Int(code) }
    }

    public func chooseSort(_ code: String) async {
        await MainActor.run { if let sort = AppModel.TitleSort(rawValue: code) { model.titleSort = sort } }
    }

    public func chooseState(_ code: String) async {
        await MainActor.run { model.titleState = WatchState(rawValue: code) }
    }

    /// The sheet of the recording whose row has `id` (`RecordedTitle.listKey`), while the list has it.
    public func open(_ id: String) async -> TitleSheetWindow? {
        await MainActor.run {
            model.allTitles.first { $0.listKey == id }.map {
                TitleSheetWindow(TitleSheetState(title: $0, model: model), model: model)
            }
        }
    }

    @MainActor
    private static func screen(_ model: AppModel) -> RecordingsScreen {
        let listed = model.shownTitles
        let problem = model.problem(for: .recorder) ?? model.problem(for: .tv)
        return RecordingsScreen(
            hasNoRecorder: model.recordingsHaveNoRecorder, noRecorder: NoRecorder(model),
            isLoading: model.recordingsAreLoading, loading: Said(AppModel.loadingRecordings),
            empty: Said(model.noRecordingsSays),
            heading: model.shownFreeBytes.map { "残り \(Format.gigabytes($0, on: model.shownFreeDevice))" } ?? "録画",
            subtitle: model.busy ?? ([model.shownDestination.map(model.titleDestinationLabel),
                                       model.titleGenre.flatMap { Codes.genreLabel[$0] }].compactMap { $0 }
                                      + ["\(listed.count) 件"]).joined(separator: " · "),
            destinations: model.titleDestinations.isEmpty ? []
                : [Labelled(code: "", label: "すべて")]
                    + model.titleDestinations.map { Labelled(code: $0.destination, label: $0.label) },
            destination: model.shownDestination ?? "",
            genres: [Labelled(code: "", label: "すべて \(model.titlesOnTheShownDisk.count)")]
                + Codes.genreLabel.keys.sorted().compactMap { level in
                    guard let count = model.titleGenreCounts[level], count > 0 else { return nil }
                    return Labelled(code: "\(level)", label: "\(Codes.genreLabel[level] ?? "") \(count)")
                },
            genre: model.titleGenre.map { "\($0)" } ?? "",
            sorts: AppModel.TitleSort.allCases.map { Labelled(code: $0.rawValue, label: $0.label) },
            sort: model.titleSort.rawValue,
            states: [Labelled(code: "", label: "すべて")] + WatchState.allCases.map { Labelled(code: $0.rawValue, label: $0.label) },
            state: model.titleState?.rawValue ?? "",
            filtering: model.shownDestination != nil || model.titleGenre != nil || model.titleState != nil
                || model.titleSort != .newest,
            tvNote: model.tvTitlesNote?.asABody ?? "",
            rows: listed.map { row($0, model) },
            line: model.busy ?? problem?.asABody ?? "", lineIsAProblem: model.busy == nil && problem != nil,
            loadKey: "\(model.connected && !model.offline)", tvKey: model.tvTitlesToRead,
            outdatedKey: "\(model.titlesOutOfStep)")
    }

    @MainActor
    private static func row(_ title: RecordedTitle, _ model: AppModel) -> RecordingRow {
        var parts = [Format.dateTime.string(from: title.start)]
        if let disk = model.diskShown(title) { parts.append(disk) }
        let channel = model.channelName(for: title)
        if !channel.isEmpty { parts.append(channel) }
        if title.lengthKnown { parts.append(Format.duration(title.durationSec)) }
        if let size = Format.size(of: title) { parts.append(size) }
        if let quality = title.qualityName { parts.append(quality) }
        return RecordingRow(id: title.listKey, title: title.title, recording: title.recording, protected: title.protected,
                            details: parts.joined(separator: " · "), watched: title.watchState.label,
                            unwatched: title.watchState == .unwatched, genre: title.genre?.label ?? "")
    }
}
