import Foundation
import RecorderKit
import SwiftUI

/// The guide as the screens read it: the day and the clock, which broadcasting types are behind and
/// fetching them, the cache, the logos, the search, and which channels are shown.
extension AppModel {
    /// Today, at this minute. Tapping the guide tab while already on it scrolls to the top of the day by
    /// itself, and the top of a broadcast day is four in the morning, which is nobody's idea of home.
    ///
    /// The programmes are read again when that changed the day, and the ask to go to now waits for them, so
    /// that it is answered from the day it names.
    func goToNow() {
        let before = day
        followTheClock()
        day = days.first ?? Date()
        guard day != before else {
            nowRequests += 1
            return
        }
        Task {
            await reloadFromCache()
            nowRequests += 1
        }
    }

    /// Moves the day strip on when the broadcast day on air is no longer its first: a process the system
    /// kept alive overnight comes back to the days it worked out the evening before. The day on screen
    /// stays if it is still in the strip, and otherwise goes to the first.
    ///
    /// Asked wherever the reader arrives -- the app starting, coming back to it, going back to now -- because
    /// nothing says when four in the morning has passed: `significantTimeChangeNotification` comes at
    /// midnight. Returns whether `day` moved, which leaves on screen the programmes of a day no longer shown.
    @discardableResult
    func followTheClock() -> Bool {
        let current = GuideStore.broadcastDays()
        guard current.first != days.first else { return false }
        days = current
        guard !days.contains(day) else { return false }
        day = days.first ?? day
        return true
    }

    /// The broadcasting types the recorder has not been asked for since it last rebuilt its guide files, or
    /// never: the ones worth fetching again (`GuideRefresh.staleTypes`).
    var staleBroadcastingTypes: [String] { GuideRefresh.staleTypes(counts) }

    /// Whether any broadcasting type is behind the recorder's last rebuild.
    var guideIsStale: Bool { !staleBroadcastingTypes.isEmpty }

    /// Whether the guide is on its way: being downloaded, or about to be, by a connect that has reached the
    /// recorder and found the cache behind -- it reads the reservations and the lists first, and then starts
    /// the refresh (`RecorderHost.refreshTheGuideAfterTheConnect`), which is about to be counted for the turns
    /// before it is. An empty guide says so then, rather than that there is nothing for the day.
    var guideOnItsWay: Bool {
        guideDownloads > 0 || (connecting && connected && guideIsStale)
            || (recorderHost.refreshesTheGuideAfterAConnect && guideIsStale)
    }

    /// What the cache holds now, read again where it differs from what this model read from it last, so that
    /// whether the guide is behind (`guideIsStale`) is judged by the cache and not by this model's copy, which
    /// would fetch every type again each morning: the overnight run writes the cache without going through the
    /// model, in this very process when the app was kept alive behind it. What it wrote goes on screen as well.
    func keepUpWithTheCache() async {
        if let store, let cached = try? await store.counts(), cached != counts { await reloadFromCache() }
    }

    /// Downloads the broadcasting types told and replaces what the cache holds for each, as a connect asks for
    /// it: the driver's step (`RecorderDriver.refreshGuide`). A connect asks with nobody having pressed, and
    /// lets what it came to go: what failed is on the line.
    @discardableResult
    func refreshGuide(_ which: GuideAsked) async -> GuideRefreshed {
        await fetchingTheGuide { driver, stored in await driver.refreshGuide(which, stored: stored) }
    }

    /// 番組表を更新, on the guide's tab and in Settings: every broadcasting type, the driver's to fetch and to
    /// connect for first where the recorder cannot be asked (`RecorderDriver.refreshGuideByHand`). What it came
    /// to is handed back as the driver hands it over, for the screen that asked to say (`GuideRefreshed.said`):
    /// the two buttons show it in an alert, the guide's tab having no line of what went wrong while a guide is
    /// on screen.
    func refreshGuideByHand() async -> GuideRefreshed {
        await fetchingTheGuide { driver, stored in await driver.refreshGuideByHand(stored: stored) }
    }

    /// A refresh of the guide as the screens have it, whichever asks: counted while it is out
    /// (`guideDownloads`), each type on screen as soon as it is stored, so that the first run does not wait for
    /// BS, CS and BS4K behind the terrestrial programmes it opens on, and the cache read once more as it ends.
    /// A type that fails is passed over (see `GuideRefresh.run`), said on screen a line per type, and fetched
    /// again at the next connect.
    ///
    /// Whether anything is asked is the driver's to say, at its own doors: the app keeps no copy of them. One
    /// turned away there comes back in the turn it was asked in, and ends in the read of the cache like any
    /// other.
    private func fetchingTheGuide(
        _ refresh: @MainActor (RecorderDriver, @escaping @MainActor @Sendable (String) async -> Void) async
            -> GuideRefreshed) async -> GuideRefreshed {
        guard let recorderDriver else { return .notConnected }
        guideDownloads += 1
        defer { guideDownloads -= 1 }
        let refreshed = await refresh(recorderDriver) { _ in await self.reloadFromCache() }
        // Whatever happened. A type stored before the recorder fell silent over its logos was never reported
        // stored, and a type the recorder had no file for changed only its mark -- which is what says it need
        // not be asked for again, and which the model goes by.
        await reloadFromCache()
        return refreshed
    }

    /// Reads what the screens show of the guide from the cache. What could not be read is said on the phone's
    /// own line, whoever asked for the read -- a refresh of the recorder's among them: the reader of the database
    /// is the app -- and a read that went through takes that line down.
    func reloadFromCache() async {
        guard let store else { return }
        guideReads += 1
        defer { guideReads -= 1 }
        do {
            counts = try await store.counts()
            channels = try await store.channels(broadcasting: broadcasting)
            // The channel the list is narrowed to has to be one the guide shows. Hidden, it stayed chosen, and
            // the list stayed empty with nothing to say why: the menu that would undo it no longer named it.
            if let serviceFilter, !channels.contains(where: { $0.serviceID == serviceFilter }) {
                self.serviceFilter = nil
            }
            let everyChannel = try await store.channels(includeHidden: true)
            channelNames = Dictionary(
                everyChannel.compactMap { channel in
                    Codes.broadcasting[channel.broadcasting].map { ("\($0)-\(channel.serviceID)", channel.name) }
                },
                uniquingKeysWith: { first, _ in first })
            channelLogos = Dictionary(
                everyChannel.compactMap { channel in
                    channel.logo.map { ("\(channel.broadcasting)-\(channel.serviceID)", $0) }
                },
                uniquingKeysWith: { first, _ in first })
            programs = try await store.day(day, broadcasting: broadcasting)
            phoneProblem = nil
        } catch {
            phoneProblem = "番組表を読み込めませんでした: \(error)"
        }
    }

    func logo(for program: GuideProgramRow) -> Data? {
        channelLogos["\(program.broadcasting)-\(program.serviceID)"]
    }

    /// A reservation names its channel by the numeric broadcasting type, which the logos are not keyed by.
    /// Stations whose logo the recorder never received have none, so this is often nil on purpose.
    func logo(for reservation: Reservation) -> Data? {
        logo(broadcastingType: reservation.broadcastingType, serviceID: reservation.serviceID)
    }

    func logo(for title: RecordedTitle) -> Data? {
        logo(broadcastingType: title.broadcastingType, serviceID: title.serviceID)
    }

    private func logo(broadcastingType: Int, serviceID: Int) -> Data? {
        Codes.broadcasting(code: broadcastingType)
            .flatMap { channelLogos["\($0)-\(serviceID)"] }
    }

    /// Programmes still to come with every word of this in their title, description or details, across every
    /// broadcasting type: the ones named for it first. The search runs against the cache, so it works away
    /// from home too. At most 300, which is more than anyone reads down; `more` says when any were left out.
    func search(_ query: String) async -> GuideSearchResults {
        await start()
        guard let store else { return GuideSearchResults() }
        return (try? await store.search(query, since: Date(), limit: 300)) ?? GuideSearchResults()
    }

    /// What the list shows: the day, narrowed to one channel when the reader picked one.
    var filteredPrograms: [GuideProgramRow] {
        guard let serviceFilter else { return programs }
        return programs.filter { $0.serviceID == serviceFilter }
    }

    var channelName: String {
        guard let serviceFilter else { return "すべての局" }
        return channels.first { $0.serviceID == serviceFilter }?.name ?? "すべての局"
    }

    // MARK: - which channels the guide shows

    /// Whether the broadcasting type on screen has channels and the reader has hidden every one of them. The
    /// guide is empty then for a reason that has nothing to do with the recorder, and says so.
    var everyChannelHidden: Bool {
        channels.isEmpty && (counts[broadcasting]?.channels ?? 0) > 0
    }

    /// Every channel of one broadcasting type, hidden ones too, in the reader's order: what the screen that
    /// sets them lists. Empty until that type's guide has been fetched.
    func channelsToArrange(broadcasting: String) async throws -> [Channel] {
        await start()
        guard let store else { return [] }
        return try await store.channels(broadcasting: broadcasting, includeHidden: true)
    }

    /// Hides channels of one broadcasting type or puts them in another order (see
    /// `GuideStore.setChannelPreferences`), and reads the guide again at once, so that the guide, the grid
    /// and the channel menu are in step when the reader goes back to them. Only the cache is written; the
    /// recorder is not told, and records from a hidden channel as before.
    func setChannelPreferences(broadcasting: String, order: [Int]? = nil, hidden: [Int]? = nil) async throws {
        await start()
        guard let store else { return }
        try await store.setChannelPreferences(broadcasting: broadcasting, order: order, hidden: hidden)
        await reloadFromCache()
    }
}
