import Foundation
import RecorderKit
import SwiftUI

/// Recordings: the list, its orders and groups, one recording's details, protecting, deleting and
/// playing it, and powering the recorder on.
extension AppModel {
    // MARK: - recordings

    enum TitleSort: String, CaseIterable {
        case newest, oldest, largest

        var label: String {
            switch self {
            case .newest: "新しい順"
            case .oldest: "古い順"
            case .largest: "大きい順"
            }
        }
    }

    func loadTitles(force: Bool = false) async {
        await start()
        await loadTitlesNow(force: force)
    }

    /// The load itself, without `start()`, for anything `connect()` reaches: see there. The read is the driver's
    /// (`RecorderDriver.titles`), which hands the list over as it comes back, before the free space is read.
    func loadTitlesNow(force: Bool) async {
        guard client != nil, !unreachable, force || !titlesLoaded else { return }
        _ = await recorderDriver?.titles { list in
            self.titles = list
            self.titlesLoaded = true
            // The sets on screen were built from the list as it was. A copy one says it keeps may have gone
            // since, and deleting the others would then leave nothing.
            if !self.duplicates.isEmpty { self.recomputeDuplicates() }
        }
    }

    /// The recordings the screen is showing: filtered, then sorted.
    var shownTitles: [RecordedTitle] {
        var shown = titles
        if let titleGenre { shown = shown.filter { $0.genre?.level1 == titleGenre } }
        if let titleState { shown = shown.filter { $0.watchState == titleState } }
        switch titleSort {
        case .newest: shown.sort { $0.start > $1.start }
        case .oldest: shown.sort { $0.start < $1.start }
        case .largest: shown.sort { ($0.sizeMB ?? 0) > ($1.sizeMB ?? 0) }
        }
        return shown
    }

    var titleGroups: [TitleGroup] { TitleGroup.group(shownTitles) }

    /// How many recordings each genre holds, for the filter row.
    var titleGenreCounts: [Int: Int] {
        Dictionary(titles.compactMap { $0.genre?.level1 }.map { ($0, 1) }, uniquingKeysWith: +)
    }

    func members(of group: TitleGroup) -> [RecordedTitle] {
        shownTitles.filter { $0.seriesKey == group.key }
    }

    func channelName(for title: RecordedTitle) -> String {
        channelNames["\(title.broadcastingType)-\(title.serviceID)"]
            ?? Codes.broadcastingLabel[Codes.broadcasting(code: title.broadcastingType) ?? ""]
            ?? ""
    }

    /// Asked as a recording's sheet opens (`RecorderDriver.detail`), which is also the moment to wake a recorder
    /// that has gone to sleep.
    func detail(of title: RecordedTitle) async -> (summary: String, details: [String])? {
        await start()
        return await recorderDriver?.detail(of: title)
    }

    /// A write: the recorder stops deleting this one to make room (`RecorderDriver.protect`). What it came to, for
    /// the screen to say.
    @discardableResult
    func setProtected(_ title: RecordedTitle, _ on: Bool) async -> Altered {
        await start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        let came = await recorderDriver.protect(title, on) {
            if let index = self.titles.firstIndex(where: { $0.id == title.id }) {
                self.titles[index].protected = on
            }
        }
        // Silence may have come after the recorder made the change. The list is read again once it answers,
        // rather than guessed at.
        if came.readAgain { titlesLoaded = false }
        // which copy of a set to keep can change with it
        if case .done = came.altered, !duplicates.isEmpty { recomputeDuplicates() }
        return came.altered
    }

    /// A write, and not one that can be undone: the recording is gone from the recorder
    /// (`RecorderDriver.delete`). What it came to, for the screen to say.
    @discardableResult
    func delete(_ title: RecordedTitle) async -> Altered {
        await start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        let came = await recorderDriver.delete(title) { self.titles.removeAll { $0.id == title.id } }
        // as for protecting: silence may have come after the recording had gone
        if came.readAgain { titlesLoaded = false }
        // A set on screen may have been left with one copy, or none of the one it says it keeps.
        if case .done = came.altered, !duplicates.isEmpty { recomputeDuplicates() }
        return came.altered
    }

    /// Playback happens on the television the recorder is attached to, not here (`RecorderDriver.play`). A
    /// recorder in standby is what `needsPower` reports, and the sheet offers to turn it on for. What it came to,
    /// for the sheet to say.
    @discardableResult
    func play(_ title: RecordedTitle, _ operation: String) async -> Altered {
        await start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        return await recorderDriver.play(title, operation)
    }

    /// Turns the recorder on, which also turns on the television attached to it (`RecorderDriver.powerOn`). What
    /// it came to, for the sheet to say.
    @discardableResult
    func powerOn() async -> Altered {
        await start()
        guard let recorderDriver else { return .notDone(RecorderDriver.notConnected) }
        return await recorderDriver.powerOn()
    }
}
