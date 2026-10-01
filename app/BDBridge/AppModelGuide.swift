import Foundation
import RecorderKit
import SwiftUI

/// The guide as the screens read it: the day and the clock, which broadcasting types are behind and
/// fetching them, the cache, the logos, the search, and which channels are shown.
extension AppModel {
    /// Today, at this minute. Tapping the guide tab while already on it scrolls to the top of the day by
    /// itself, and the top of a broadcast day is four in the morning, which is nobody's idea of home.
    ///
    /// The programmes are read again when that changed the day. Moving the day alone put today's date over
    /// whichever day had been open, and the grid, finding none of it on today, came up empty. The ask to
    /// go to now waits for them, so that it is answered from the day it names.
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

    /// Moves the day strip on when the broadcast day on air is no longer its first. A process the system
    /// kept alive overnight comes back to the days it worked out the evening before: it opened on
    /// yesterday, going back to now went to yesterday, and the eighth day was out of reach. The day on screen
    /// stays if it is still in the strip -- tomorrow, looked at last night, is today now -- and otherwise
    /// goes to the first.
    ///
    /// Asked wherever the reader arrives -- the app starting, coming back to it, going back to now -- because
    /// nothing says when four in the morning has passed: `significantTimeChangeNotification` comes at
    /// midnight.
    ///
    /// Returns whether `day` moved, since the programmes on screen are then those of a day no longer shown.
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
    /// recorder and found the cache behind -- it reads the reservations first (see `connect()`). An empty
    /// guide says so then, rather than that there is nothing for the day. On the first run that is what the
    /// reader sees as soon as the tutorial closes, for as long as the first broadcasting type takes.
    var guideOnItsWay: Bool { guideDownloads > 0 || (connecting && connected && guideIsStale) }

    /// Fetching the guide is what connecting is for, so it happens without being asked: the first run
    /// otherwise lands on an empty guide with nothing to say that anything has to be fetched, and a cache
    /// the overnight run never got to would quietly stay a day behind. A cache that is already current
    /// costs nothing, which is what makes this safe on every launch.
    func refreshGuideIfStale() async {
        guard connected else { return }
        // Judged by what the cache holds now, not by what this model read from it last. The overnight run
        // writes the cache without going through the model -- in this very process, when the app was kept
        // alive behind it -- and deciding on the counts from the evening before fetched every broadcasting
        // type again each morning. What it wrote goes on screen as well.
        if let store, let cached = try? await store.counts(), cached != counts { await reloadFromCache() }
        let stale = staleBroadcastingTypes
        guard !stale.isEmpty else { return }
        await refreshGuide(only: stale)
    }

    /// Downloads the broadcasting types the recorder has -- every one unless told which -- and replaces what
    /// the cache holds for each.
    ///
    /// Each type goes on screen as soon as it is stored. Reading the cache only at the end left the first
    /// run with an empty guide until BS, CS and BS4K had come in behind the terrestrial programmes it opens
    /// on, which were there all along. A type that fails is passed over (see `GuideRefresh.run`), said on
    /// screen a line per type, and fetched again at the next connect.
    func refreshGuide(only types: [String] = GuideRefresh.broadcastingTypes) async {
        guard let client, let store, !unreachable else { return }
        guideDownloads += 1
        defer { guideDownloads -= 1 }
        var failed: [GuideRefresh.Failure] = []
        await run("番組表を取得中") { activity in
            // In a task of its own, because the guide is the app's rather than a screen's. A pull-down that
            // connected is cancelled when its screen goes away, and the refresh stops between types when it
            // is cancelled -- which is for the overnight run, whose time runs out.
            let refresh = Task {
                try await GuideRefresh.run(client: client, store: store, types: types, onType: { broadcasting in
                    let label = Codes.broadcastingLabel[broadcasting] ?? broadcasting
                    self.activities.update(activity, to: "番組表を取得中 (\(label))")
                }, onStored: { _ in
                    await self.reloadFromCache()
                })
            }
            failed = try await refresh.value.failed
        }
        if !failed.isEmpty {
            problem = failed.map { "\(GuideEmptyView.inSentence($0.broadcasting))の番組表：\($0.reason)" }
                .joined(separator: "\n")
        }
        // Whatever happened. A type stored before the recorder fell silent over its logos was never reported
        // stored, and a type the recorder had no file for changed only its mark -- which is what says it need
        // not be asked for again, and which the model goes by.
        await reloadFromCache()
    }

    func reloadFromCache() async {
        guard let store else { return }
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
        } catch {
            problem = "番組表を読み込めませんでした: \(error)"
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
    /// from home too. At most 300, which is more than anyone reads down; `more` says the words should be
    /// narrowed, rather than letting the list pass for all there is.
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
