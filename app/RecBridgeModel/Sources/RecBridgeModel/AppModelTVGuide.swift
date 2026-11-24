import Foundation
import RecorderKit

/// Which device the household's guide is fetched from. One for the household, not one per type: the two guides
/// spell things differently, and a guide whose tabs came from different devices would read oddly.
public enum GuideSourceChoice: String, Sendable {
    case recorder
    case tv

    /// Where a household's guide is fetched from, by the four facts that decide it: the television where a
    /// helper is registered and either no recorder is saved, or the one saved is known to give no guide, or the
    /// reader chose the television; the recorder otherwise, the helper registered or not, and with no helper
    /// whether or not it gives a guide. One rule for the screens, which ask the model (`AppModel.guideSource`),
    /// and for a run with no screen, which has none to ask (`BackgroundWork.guideSource(in:)`).
    static func of(recorderSaved: Bool, recorderGivesAGuide: Bool, helperRegistered: Bool,
                   preference: GuideSourceChoice) -> GuideSourceChoice {
        guard helperRegistered else { return .recorder }
        return recorderSaved && recorderGivesAGuide ? preference : .tv
    }

    /// The reader's choice where both devices could give the guide, as the settings saved it
    /// (`DefaultsKey.guideSource`): unset is the recorder.
    static func preference(in defaults: UserDefaults) -> GuideSourceChoice {
        GuideSourceChoice(rawValue: defaults.string(forKey: DefaultsKey.guideSource) ?? "") ?? .recorder
    }

    /// Whether the saved recorder gives a guide, as the screens kept what it last said of itself
    /// (`DefaultsKey.recorderGivesAGuide`): unset, a recorder never heard, is one that gives a guide.
    static func recorderGivesAGuide(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: DefaultsKey.recorderGivesAGuide) == nil
            || defaults.bool(forKey: DefaultsKey.recorderGivesAGuide)
    }
}

/// The television's guide, through the helper that runs on it: which device the guide is fetched from, and when.
/// The registration with the helper, which types are behind, the fetch and what is said of it are the package's
/// (`TVHelperGuide`); what the last fetch said is kept here.
extension AppModel {
    /// The reader's choice where both devices could give the guide: unset is the recorder.
    public var guideSourcePreference: GuideSourceChoice { .preference(in: defaults) }

    /// Where the guide is fetched from now: the television where a helper is registered and either there is no
    /// recorder, or the recorder gives no guide, or the reader chose it; the recorder otherwise, the helper
    /// registered or not (`GuideSourceChoice.of`). The other device is asked for no guide by itself: not the
    /// recorder after a connect (`guideIsStale`) or overnight, not the helper as the app starts or comes to the
    /// front (`refreshGuideFromTVIfBehind`) or overnight, the night reading the same rule from what the screens
    /// saved (`BackgroundWork.guideSource(in:)`).
    public var guideSource: GuideSourceChoice {
        .of(recorderSaved: !host.isEmpty, recorderGivesAGuide: recorderGivesAGuide, helperRegistered: helperRegistered,
            preference: guideSourcePreference)
    }

    /// Whether the recorder in play gives a guide, as far as the app knows before a connect: what the real one
    /// said of itself when it was last taken up (`savedRecorderGivesAGuide`), true while it never has; and in the
    /// demo the invented recorder's, which gives one.
    var recorderGivesAGuide: Bool { demo || savedRecorderGivesAGuide }

    /// What the real recorder said of its guide as an attach took it up, which its host has written down
    /// (`RecorderHost.keepWhetherItGivesAGuide`). Where that has made the television the device the guide is
    /// fetched from -- the first connect to a recorder that gives no guide, in a home whose helper is registered
    /// and whose guide the recorder gave until then -- the television's guide is fetched, what is behind of it, in
    /// a task the attach does not wait for, as a helper registered there fetches it at once. Said again as it was,
    /// nothing is fetched: the television's guide is fetched as the app starts and comes to the front
    /// (`refreshGuideFromTVIfBehind`), and overnight. Where it has made the recorder the source again, the connect
    /// it is part of fetches the recorder's guide over the television's, every type the television gave being
    /// behind to the recorder (`guideIsStale`).
    func recorderSaid(givesAGuide: Bool) {
        let before = guideSource
        savedRecorderGivesAGuide = givesAGuide
        guard before == .recorder, guideSource == .tv else { return }
        Task { await self.refreshGuideFromTV() }
    }

    /// The device the guide is fetched from now, as a sentence about the guide names it: by the name 番組表の取得元
    /// has for it (`SettingsWords.guideSourceName`). The recorder in a home with no helper registered, and in
    /// the demo, which has no helper.
    public var guideDeviceName: String { SettingsWords.guideSourceName(guideSource) }

    /// Whether the app holds a registration with the helper.
    public var helperRegistered: Bool { tvHelper?.isRegistered ?? false }

    /// Whether the reader has a choice to make: both a recorder that gives a guide and a registered helper. Beside
    /// a recorder that gives none there is no choice, and the choice saved is left as it was.
    public var guideSourceIsChoosable: Bool { !host.isEmpty && recorderGivesAGuide && helperRegistered }

    /// 番組表の取得元 as one line with no choice to make, where the television gives the guide (テレビ): with no
    /// recorder, or beside one that gives no guide. Nil where there is a choice, and where the recorder gives it
    /// with none, when nothing is said of where it comes from.
    public var guideSourceAlone: String? {
        !guideSourceIsChoosable && guideSource == .tv ? SettingsWords.guideSourceName(.tv) : nil
    }

    /// The helper's client for the television at `host`, made with the television's link outside the demo. The
    /// demo's television has no helper.
    func makeTVHelper(for host: String) {
        guard !demo else { return }
        tvHelper = TVHelperGuide(client: TVHelperClient(host: host, transport: surroundings.tvTransport(host),
                                                        tokens: surroundings.tvHelperTokens))
    }

    // MARK: - registration

    /// Registers with the helper by the code the television shows, and says what went wrong, or nil. Where the
    /// television gives the guide once the helper is registered, the guide is taken over to it and the
    /// television's fetched at once (`adoptGuideSource`): in a household with no recorder, in one whose recorder
    /// gives no guide, and in one with a recorder whose reader chose テレビ before, the helper registered again.
    /// Where the recorder still gives it, nothing is fetched, and the reader chooses in the settings.
    public func registerHelper(code: String) async -> String? {
        guard let tvHelper else { return TVDriver.notConnected }
        if let why = await tvHelper.register(code: code, label: surroundings.helperLabel) { return why }
        helperProblem = nil
        if guideSource == .tv { await adoptGuideSource() }
        return nil
    }

    /// Forgets the registration. What the cache holds of the television's guide stays until the recorder's
    /// replaces it, which is at the next connect to the recorder: every type the television gave is behind to
    /// it (`GuideRefresh.staleTypes`).
    public func forgetHelper() {
        tvHelper?.forgetRegistration()
        helperProblem = nil
    }

    // MARK: - choosing

    public func setGuideSourcePreference(_ choice: GuideSourceChoice) async {
        guard choice != guideSourcePreference else { return }
        defaults.set(choice.rawValue, forKey: DefaultsKey.guideSource)
        await adoptGuideSource()
    }

    /// Takes the guide over to the device it is fetched from now: every type's marks are forgotten, so that
    /// the device fetches them all, and the fetch is asked for. The programmes stay until each type's come in;
    /// a type that device does not have is emptied by its fetch: the television's once the helper has said
    /// what it has (`GuideStore.empty`), the recorder's as it answers that it has no file of the type
    /// (`GuideStore.noteNoGuide`).
    func adoptGuideSource() async {
        if let store {
            for broadcasting in GuideRefresh.broadcastingTypes {
                try? await store.forgetGuideMarks(broadcasting: broadcasting)
            }
        }
        tvHelper?.forgetTheCheck()
        await reloadFromCache()
        switch guideSource {
        case .tv: await refreshGuideFromTV(every: true)
        case .recorder: await refreshGuide(.all)
        }
    }

    // MARK: - 番組表を更新

    /// The press's button, and the title of the alert that says what it had to say, on the guide's tab and in
    /// Settings alike.
    public static let refreshGuideLabel = "番組表を更新"
    public static let refreshFailedTitle = "番組表を取得できませんでした"

    /// The press of 番組表を更新, on the guide's tab and in Settings, by whichever device the guide is fetched
    /// from: every type, and what there is to say of it, or nil.
    public func refreshGuideByHandFromSource() async -> String? {
        switch guideSource {
        case .tv: await refreshGuideFromTV(every: true)
        case .recorder: await refreshGuideByHand().said
        }
    }

    /// Whether that press is live: not while a fetch from the television is out; for the recorder, not unless
    /// connected, not while the recorder works, and not for a recorder that has no guide to give, which the
    /// empty guide says in so many words. Held by nothing the other device does.
    public var canRefreshGuideByHand: Bool {
        switch guideSource {
        case .tv: !(tvHelper?.isFetching ?? false)
        case .recorder: connected && !isBusy(for: .recorder) && info?.epgCapable != false
        }
    }

    // MARK: - fetching

    /// Fetches what is behind where the television is the guide's source and the helper was not asked within the
    /// hour (`TVHelperGuide.isDue`). What the app does as it starts and as it comes to the front. Asked within the
    /// hour, it reads the cache again where that differs from what this model read last (`keepUpWithTheCache`),
    /// as a connect to the recorder does: the overnight run fetches the television's guide with no model to tell,
    /// in this very process when the app was kept alive behind it. A fetch reads the cache again as it ends.
    func refreshGuideFromTVIfBehind() async {
        guard guideSource == .tv else { return }
        guard tvHelper?.isDue() ?? false else { return await keepUpWithTheCache() }
        await refreshGuideFromTV()
    }

    /// Fetches the television's guide (`TVHelperGuide.fetch`): what is behind, or every type (`every`), as
    /// 番組表を更新 asks, under a line of the television's, each type on screen as soon as it is stored. Keeps
    /// what it said, and hands it back.
    @discardableResult
    func refreshGuideFromTV(every: Bool = false) async -> String? {
        guard guideSource == .tv, let tvHelper, let store else { return nil }
        let said = await tvHelper.fetch(every: every, into: store, on: tv, stored: { _ in await self.reloadFromCache() })
        helperProblem = said
        await reloadFromCache()
        return said
    }
}
