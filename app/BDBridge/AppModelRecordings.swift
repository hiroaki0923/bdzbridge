import Foundation
import RecorderKit
import SwiftUI

/// Recordings: the list, its orders and groups, one recording's details, protecting, deleting and
/// playing it, and powering the recorder on.
///
/// Each device's are read and kept by its host, and here the two lists are only put together for the screens, as
/// the reservations are, a write being handed to the host of the device that holds the row
/// (`RecordedTitle.device`). A television's are read beside the recorder's, neither waiting on the other, and go
/// with its host. What a television's rows do not have -- playing, the duplicate scan -- is not offered of them.
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

    /// What pulling the recorder's recordings down asks for (`RecorderHost.refreshTitles`).
    func refreshTitles() async { await recorderHost.refreshTitles() }

    /// Pulling the recordings' tab down, which is the reader asking: both devices side by side, so that neither
    /// device's silence holds the other's list up, and each but while a job walks its own.
    func pullDownTitles() async {
        async let television: Void? = jobIsOnTheTelevision ? nil : tvHost?.refreshTitles()
        await refreshTitles()
        await television
    }

    /// The television's recordings read, as the recordings tab does when it opens, in a task of their own beside
    /// the recorder's. Nothing with no television in play.
    func loadTVTitles() async { await tvHost?.loadTitles() }

    /// What says when the television's recordings are to be read: each television, and each time it was attached.
    var tvTitlesToRead: String { "\(tvTimesForgotten)-\(tv?.session.timesAttached ?? 0)" }

    /// What says when a list that may still be coming is to be waited for: as `tvTitlesToRead`, for a television
    /// lost during a wait, and as the list comes to be one.
    var tvTitlesToWaitFor: String { "\(tvTitlesToRead)-\(tvHost?.titlesAccount == .mayStillBeComing)" }

    /// Reads again a television's list that may still be coming, for as long as the screen's task lasts
    /// (`TVHost.waitForTitles`), a screen left going on with what is left of the wait.
    func waitForTVTitles() async { await tvHost?.waitForTitles() }

    /// Whether that wait is under way, for the strip and the screen to say so.
    var waitingForTVTitles: Bool { tvHost?.waitingForTitles == true }

    /// What the list says of the television's recordings under its rows: only where a read has found more on the
    /// disk than the list holds, and while its rows are among what is shown. Not an error, which the strip would say.
    var tvTitlesNote: String? {
        guard tvHost?.titlesAccount == .someAreMissing,
              shownDestination == nil || shownDestination == TVDriver.recordsTo else { return nil }
        return TVDriver.titlesMissing
    }

    /// Whether the television has anything for the tab to show with no recorder connected: its rows, or that they
    /// are on their way or short of its disk. Otherwise the tab says what it says of a recorder that is not there,
    /// as it does with no television, rows held of that recorder or not.
    var tvHasSomethingToShow: Bool {
        tvHost?.titles.isEmpty == false || tvTitlesNote != nil || waitingForTVTitles
    }

    /// The recordings of both devices, the recorder's first and in no order of the list's: put together each time
    /// they are read, and kept apart where they are held, since a read of either replaces its own list whole.
    var allTitles: [RecordedTitle] { tvHost.map { titles + $0.titles } ?? titles }

    /// Whether the list held has been left behind by the USB disk in the slot (`RecorderHost.usbListOutdated`), which
    /// the screen goes by, and the read that puts that right.
    var usbListOutdated: Bool { recorderHost.usbListOutdated }

    /// Whether the screen has anything to put right after the USB disk: the list (`usbListOutdated`), or a filter on
    /// a disk, or a television, no longer offered.
    var titlesOutOfStep: Bool { usbListOutdated || (titleDestination != nil && shownDestination == nil) }

    /// Puts that right. A disk let go of takes the filter on it for good: come back, it is not to narrow the list by
    /// itself. The read goes afresh: the flag goes up as a read hands its list over, with that read still out for
    /// the free space, and folded into it this would come to nothing, the flag staying up and the screen not asking
    /// again.
    func loadOutdatedTitles() async {
        if shownDestination == nil { titleDestination = nil }
        if usbListOutdated { await recorderHost.loadTitles(force: true, afresh: true) }
    }

    /// One of the places recordings are, as the filter offers it.
    struct TitleDestination: Hashable {
        /// The recorder's id for one of its disks, or `TVDriver.recordsTo`.
        var destination: String
        var label: String
    }

    /// What the recordings can be narrowed to: the recorder's disks, and the television while it has its disk.
    /// Nothing in a home with one of them, which is then drawn no filter: there is nothing to tell apart. Beside a
    /// television the recorder's internal disk is one of them, with no USB disk as well, once a recorder has been
    /// added: `diskChoices` has nothing to choose from then.
    var titleDestinations: [TitleDestination] {
        var disks = diskChoices
        if disks.isEmpty, !host.isEmpty { disks = [RecorderDisk.internalDisk] }
        var offered = disks.map {
            TitleDestination(destination: $0.destination, label: RecorderDisk.label($0.destination, named: $0.name))
        }
        if tvDriver?.facts.storage?.mounted == true {
            offered.append(TitleDestination(destination: TVDriver.recordsTo, label: DeviceSlot.tv.label))
        }
        return offered.count > 1 ? offered : []
    }

    /// The place the recordings are narrowed to: the one picked, while it is offered. A disk that has left the slot
    /// is let go of at once, since the menu that picked it goes with it and nothing else would get the reader out of
    /// a list narrowed to nothing, and the pick after it (`loadOutdatedTitles`).
    var shownDestination: String? {
        titleDestination.flatMap { id in titleDestinations.contains { $0.destination == id } ? id : nil }
    }

    /// The free space the title bar shows: the USB disk's or the television's when the list is narrowed to it,
    /// otherwise the internal disk's, as it always was.
    var shownFreeBytes: Int? {
        switch shownDestination {
        case RecorderDisk.usbID: usbDisk?.freeBytes
        case TVDriver.recordsTo: tvDriver?.facts.storage?.freeBytes
        default: storage?.free
        }
    }

    /// One of `titleDestinations` as the screens name it.
    func titleDestinationLabel(_ destination: String) -> String {
        destination == TVDriver.recordsTo ? DeviceSlot.tv.label : diskLabel(destination)
    }

    /// The disk a recording's row names, or nil for none: the one rule (`RecorderDisk.shown`), so that a row of the
    /// internal disk is drawn as it always was. By the disk the row was read from, which may no longer be the one in
    /// the slot. A television's row is named by the device, its one disk being no name to anybody.
    func diskShown(_ title: RecordedTitle) -> String? {
        guard title.device == .recorder else { return title.device.label }
        return RecorderDisk.shown(title.destination, on: .recorder, usb: title.readFrom ?? usbDisk)
    }

    /// The recordings of the place the list is narrowed to, or all of them.
    var titlesOnTheShownDisk: [RecordedTitle] {
        shownDestination.map { disk in allTitles.filter { $0.destination == disk } } ?? allTitles
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
        allTitles.first { $0.listKey == title.listKey }
    }

    /// A television's row names its station; a recorder's, a number the guide knows.
    func channelName(for title: RecordedTitle) -> String {
        title.channelName
            ?? channelNames["\(title.broadcastingType)-\(title.serviceID)"]
            ?? Codes.broadcastingLabel[Codes.broadcasting(code: title.broadcastingType) ?? ""]
            ?? ""
    }

    /// Asked as a recording's sheet opens (`RecorderHost.detail`). A television's row says it itself, and nothing
    /// is asked.
    func detail(of title: RecordedTitle) async -> (summary: String, details: [String])? {
        guard title.device == .recorder else { return (title.summary ?? "", [title.details].compactMap { $0 }) }
        return await recorderHost.detail(of: title)
    }

    /// Why a recording cannot be changed now, for the screens to hold its buttons and say so: the rule of the driver
    /// of the device that holds it (`RecorderDriver.whyNot(altering:usb:)`, with the USB disk known;
    /// `TVDriver.whyNot(altering:)`). Nil for a recording of the internal disk.
    func whyNot(altering title: RecordedTitle) -> String? {
        title.device == .tv ? TVDriver.whyNot(altering: title) : RecorderDriver.whyNot(altering: title, usb: usbDisk)
    }

    /// Why a recording cannot be deleted now, by the rule the delete's own door asks
    /// (`RecorderDriver.whyNot(deleting:usb:)`, `TVDriver.whyNot(deleting:)`).
    func whyNot(deleting title: RecordedTitle) -> String? {
        title.device == .tv ? TVDriver.whyNot(deleting: title) : RecorderDriver.whyNot(deleting: title, usb: usbDisk)
    }

    /// Whether one recording may be deleted or protected now, for the buttons that do it: a recorder's by the
    /// recorder's work (`RecorderHost.canAlterARecording`), a television's by its own, and neither beside a run over
    /// that device's rows, which walks the list those would write to.
    func canAlter(_ title: RecordedTitle) -> Bool {
        title.device == .tv ? !isBusy(for: .tv) && !jobIsOnTheTelevision : canAlterARecording
    }

    /// Why a recording cannot be played now, by the rule the play's own door asks
    /// (`RecorderDriver.whyNot(playing:usb:)`).
    func whyNot(playing title: RecordedTitle) -> String? { RecorderDriver.whyNot(playing: title, usb: usbDisk) }

    /// A write: the device stops deleting this one (`RecorderHost.setProtected`, `TVHost.setProtected`), handed to
    /// the host of the device that holds it, before anything else is done.
    @discardableResult
    func setProtected(_ title: RecordedTitle, _ on: Bool) async -> Altered {
        guard title.device == .tv else { return await recorderHost.setProtected(title, on) }
        return await tvHost?.setProtected(title, on) ?? .notDone(DeviceSlot.tv.notConnected)
    }

    /// A write, and not one that can be undone (`RecorderHost.delete`, `TVHost.delete`), handed over the same way.
    @discardableResult
    func delete(_ title: RecordedTitle) async -> Altered {
        guard title.device == .tv else { return await recorderHost.delete(title) }
        return await tvHost?.delete(title) ?? .notDone(DeviceSlot.tv.notConnected)
    }

    /// Playback on the television the recorder is attached to (`RecorderHost.play`).
    @discardableResult
    func play(_ title: RecordedTitle, _ operation: String) async -> Altered {
        await recorderHost.play(title, operation)
    }

    /// Turns the recorder on (`RecorderHost.powerOn`).
    @discardableResult
    func powerOn() async -> Altered { await recorderHost.powerOn() }
}
