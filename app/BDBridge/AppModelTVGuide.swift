import Foundation
import RecorderKit

/// Which device the household's guide is fetched from. One for the household, not one per type: the two guides
/// spell things differently, and a guide whose tabs came from different devices would read oddly.
enum GuideSourceChoice: String {
    case recorder
    case tv
}

/// The television's guide, through the helper that runs on it (`TVHelperClient`): the registration with the
/// helper, which device the guide is fetched from, and the fetch itself. The helper is asked without a link of
/// its own: it is never woken, wants no check before a write, and what is asked of it is read only, so its
/// client is made with the television's link and asked straight.
extension AppModel {
    /// What the helper lists this phone as.
    static let helperLabel = "RecBridge (iPhone)"
    /// How long the helper's copy is trusted before the helper is asked again whether it changed.
    static let tvGuideCheckInterval: TimeInterval = 3600

    /// The reader's choice where both devices could give the guide: unset is the recorder.
    var guideSourcePreference: GuideSourceChoice {
        GuideSourceChoice(rawValue: defaults.string(forKey: DefaultsKey.guideSource) ?? "") ?? .recorder
    }

    /// Where the guide is fetched from now: the television where a helper is registered and either there is no
    /// recorder or the reader chose it; the recorder otherwise, the helper registered or not.
    var guideSource: GuideSourceChoice {
        guard helperRegistered else { return .recorder }
        return host.isEmpty ? .tv : guideSourcePreference
    }

    /// Whether the app holds a registration with the helper. Read through the count of changes to it, so that a
    /// screen reading this is told when it changes: the token itself is in a store the screens do not watch.
    var helperRegistered: Bool {
        _ = helperTimesChanged
        return tvHelper?.isRegistered ?? false
    }

    /// Whether the reader has a choice to make: both a recorder and a registered helper.
    var guideSourceIsChoosable: Bool { !host.isEmpty && helperRegistered }

    /// The helper's client for the television at `host`, made with the television's link outside the demo. The
    /// demo's television has no helper.
    func makeTVHelper(for host: String) {
        guard !demo else { return }
        tvHelper = TVHelperClient(host: host, transport: surroundings.tvTransport(host), tokens: surroundings.tvHelperTokens)
    }

    // MARK: - registration

    /// Registers with the helper by the code the television shows, and says what went wrong, or nil. In a
    /// household with no recorder the television's guide is fetched at once; with one, the reader chooses in the
    /// settings.
    func registerHelper(code: String) async -> String? {
        guard let tvHelper else { return TVDriver.notConnected }
        do {
            try await tvHelper.probe(timeout: 5)
            try await tvHelper.pair(code: code, label: Self.helperLabel)
        } catch let error as any DeviceError {
            return error.explanation
        } catch {
            return String(describing: error)
        }
        helperTimesChanged += 1
        helperProblem = nil
        if host.isEmpty { await adoptGuideSource() }
        return nil
    }

    /// Forgets the registration. The helper keeps listing the phone until it is taken off its list on the
    /// television. What the cache holds of the television's guide stays until the recorder's replaces it.
    func forgetHelper() {
        tvHelper?.forgetRegistration()
        helperTimesChanged += 1
        helperProblem = nil
    }

    // MARK: - choosing

    func setGuideSourcePreference(_ choice: GuideSourceChoice) async {
        guard choice != guideSourcePreference else { return }
        defaults.set(choice.rawValue, forKey: DefaultsKey.guideSource)
        await adoptGuideSource()
    }

    /// Takes the guide over to the device it is fetched from now: every type's marks are forgotten, so that
    /// the device fetches them all, and the fetch is asked for. The programmes stay until each type's come in.
    func adoptGuideSource() async {
        if let store {
            for broadcasting in GuideRefresh.broadcastingTypes {
                try? await store.forgetGuideMarks(broadcasting: broadcasting)
            }
        }
        lastTVGuideCheck = nil
        await reloadFromCache()
        switch guideSource {
        case .tv: await refreshGuideFromTV(every: true)
        case .recorder: await refreshGuide(.all)
        }
    }

    // MARK: - 番組表を更新

    /// The press of 番組表を更新, on the guide's tab and in Settings, by whichever device the guide is fetched
    /// from: every type, and what there is to say of it, or nil.
    func refreshGuideByHandFromSource() async -> String? {
        switch guideSource {
        case .tv: await refreshGuideFromTV(every: true)
        case .recorder: await refreshGuideByHand().said
        }
    }

    /// Whether that press is live: not while a fetch from the television is out; for the recorder, not unless
    /// connected, not while the recorder works, and not for a recorder that has no guide to give, which the
    /// empty guide says in so many words. Held by nothing the other device does.
    var canRefreshGuideByHand: Bool {
        switch guideSource {
        case .tv: guideDownloads == 0
        case .recorder: connected && !isBusy(for: .recorder) && info?.epgCapable != false
        }
    }

    // MARK: - fetching

    /// Asks the helper whether its copies have changed since the cache was filled from them, and fetches the
    /// types that have, where the television is the guide's source and the helper was not asked within the
    /// hour. What the app does as it starts and as it comes to the front.
    func refreshGuideFromTVIfBehind() async {
        guard guideSource == .tv else { return }
        if let lastTVGuideCheck, Date().timeIntervalSince(lastTVGuideCheck) < Self.tvGuideCheckInterval { return }
        await refreshGuideFromTV()
    }

    /// Fetches the television's guide: the types the helper has newer copies of than the cache was filled from,
    /// or every type it has (`every`), as 番組表を更新 asks. Says what went wrong, or nil. One fetch at a time;
    /// asked while one is out, it waits for that one and says what it said.
    ///
    /// Under a line of the television's, so that the recorder's buttons are not held by it. A type that fails is
    /// passed over and said; silence ends the fetch, as it does the recorder's.
    @discardableResult
    func refreshGuideFromTV(every: Bool = false) async -> String? {
        guard guideSource == .tv, let tvHelper, let store else { return nil }
        if let fetching = tvGuideFetch {
            await fetching.value
            return helperProblem
        }
        let fetch = Task { @MainActor in
            await self.fetchFromTV(tvHelper, into: store, every: every)
        }
        tvGuideFetch = fetch
        await fetch.value
        tvGuideFetch = nil
        return helperProblem
    }

    private func fetchFromTV(_ helper: TVHelperClient, into store: GuideStore, every: Bool) async {
        guideDownloads += 1
        let token = activities.begin("番組表を取得中（テレビ）")
        televisionLines.insert(token)
        defer {
            guideDownloads -= 1
            activities.end(token)
            televisionLines.remove(token)
        }
        let info: TVHelperInfo
        do {
            info = try await helper.info()
        } catch {
            helperProblem = Self.helperSaid(error)
            return
        }
        // The types the app keeps that the television has programmes of; CS4K is left out either way.
        var types = GuideRefresh.broadcastingTypes.filter { (info.types[$0]?.programs ?? 0) > 0 }
        if !every {
            var behind: [String] = []
            for broadcasting in types {
                let changed = info.types[broadcasting]?.changedAt ?? Date()
                let filledFrom = try? await store.helperChanged(broadcasting: broadcasting)
                if filledFrom.map({ changed > $0 }) ?? true || (counts[broadcasting]?.programs ?? 0) == 0 {
                    behind.append(broadcasting)
                }
            }
            types = behind
        }
        lastTVGuideCheck = Date()
        guard !types.isEmpty else {
            helperProblem = nil
            return
        }
        let outcome = await GuideRefresh.run(client: helper, store: store, types: types, onType: { broadcasting in
            self.activities.update(token, to: "番組表を取得中（テレビ: \(Codes.broadcastingLabel[broadcasting] ?? broadcasting)）")
            return true
        }, onStored: { _ in await self.reloadFromCache() })
        for broadcasting in outcome.answered {
            try? await store.noteHelperChanged(broadcasting: broadcasting, at: info.types[broadcasting]?.changedAt ?? Date())
        }
        await reloadFromCache()
        var lines = RecorderDriver.guideFailed(outcome.failed)
        if outcome.stopped == .silent { lines.append(TVHelperError.transport("").explanation) }
        helperProblem = lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func helperSaid(_ error: any Error) -> String {
        (error as? any DeviceError)?.explanation ?? String(describing: error)
    }
}
