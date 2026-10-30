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

    /// Whether the list held has been left behind by the USB disk in the slot (`RecorderHost.usbListOutdated`), which
    /// the screen goes by, and the read that puts that right.
    var usbListOutdated: Bool { recorderHost.usbListOutdated }

    func loadOutdatedTitles() async {
        if usbListOutdated { await loadTitles(force: true) }
    }

    /// The disk the recordings are narrowed to: the one picked, while it is offered. A disk that has left the slot
    /// is let go of, since the menu that picked it goes with it and nothing else would get the reader out of a
    /// list narrowed to nothing.
    var shownDestination: String? {
        titleDestination.flatMap { id in diskChoices.contains { $0.destination == id } ? id : nil }
    }

    /// The free space the title bar shows: the USB disk's when the list is narrowed to it, otherwise the internal
    /// disk's, as it always was.
    var shownFreeBytes: Int? {
        shownDestination == RecorderDisk.usbID ? usbDisk?.freeBytes : storage?.free
    }

    /// The disk a recording's row names, or nil for none: the one rule (`RecorderDisk.shown`), so that a row of the
    /// internal disk is drawn as it always was.
    func diskShown(_ title: RecordedTitle) -> String? {
        RecorderDisk.shown(title.destination, on: .recorder, usb: usbDisk)
    }

    /// The recordings of the disk the list is narrowed to, or all of them.
    var titlesOnTheShownDisk: [RecordedTitle] {
        shownDestination.map { disk in titles.filter { $0.destination == disk } } ?? titles
    }

    /// The recordings the screen is showing: filtered, then sorted.
    var shownTitles: [RecordedTitle] {
        var shown = titlesOnTheShownDisk
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

    /// How many recordings each genre holds, for the filter row, of the disk the list is narrowed to.
    var titleGenreCounts: [Int: Int] {
        Dictionary(titlesOnTheShownDisk.compactMap { $0.genre?.level1 }.map { ($0, 1) }, uniquingKeysWith: +)
    }

    func members(of group: TitleGroup) -> [RecordedTitle] {
        shownTitles.filter { $0.seriesKey == group.key }
    }

    /// The row of the list that is `title`, or nil once it has left: by `RecordedTitle.listKey`, since a list read
    /// again from another disk can hold another recording under the same number.
    func row(like title: RecordedTitle) -> RecordedTitle? {
        titles.first { $0.listKey == title.listKey }
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

    /// Why a recording cannot be changed now, for the screens to hold its buttons and say so: the driver's rule
    /// (`RecorderDriver.whyNot(altering:usb:)`), with the USB disk known. Nil for a recording of the internal disk.
    func whyNot(altering title: RecordedTitle) -> String? { RecorderDriver.whyNot(altering: title, usb: usbDisk) }

    /// Why a recording cannot be deleted now, by the rule the delete's own door asks
    /// (`RecorderDriver.whyNot(deleting:usb:)`).
    func whyNot(deleting title: RecordedTitle) -> String? { RecorderDriver.whyNot(deleting: title, usb: usbDisk) }

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
