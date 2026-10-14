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

    func loadTitles(force: Bool = false) async { await recorderHost.loadTitles(force: force) }

    /// What pulling the recordings down asks for (`RecorderHost.refreshTitles`).
    func refreshTitles() async { await recorderHost.refreshTitles() }

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

    /// Asked as a recording's sheet opens (`RecorderHost.detail`).
    func detail(of title: RecordedTitle) async -> (summary: String, details: [String])? {
        await recorderHost.detail(of: title)
    }

    /// A write: the recorder stops deleting this one to make room (`RecorderHost.setProtected`).
    @discardableResult
    func setProtected(_ title: RecordedTitle, _ on: Bool) async -> Altered {
        await recorderHost.setProtected(title, on)
    }

    /// A write, and not one that can be undone (`RecorderHost.delete`).
    @discardableResult
    func delete(_ title: RecordedTitle) async -> Altered { await recorderHost.delete(title) }

    /// Playback on the television the recorder is attached to (`RecorderHost.play`).
    @discardableResult
    func play(_ title: RecordedTitle, _ operation: String) async -> Altered {
        await recorderHost.play(title, operation)
    }

    /// Turns the recorder on (`RecorderHost.powerOn`).
    @discardableResult
    func powerOn() async -> Altered { await recorderHost.powerOn() }
}
