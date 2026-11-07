import Foundation
import Observation

/// The television's guide, through the helper that runs on it (`TVHelperClient`): the registration with the
/// helper, when it is asked again whether its copies changed, which types are behind, the fetch, and what is said
/// of it. Which device the guide is fetched from is the app's choice, and what is kept of what a fetch said is
/// the app's too.
///
/// The helper is asked without a link of its own: it is never woken, wants no check before a write, and what is
/// asked of it is read only. The fetch's line goes up on the television's link's host, given with each fetch,
/// so that the recorder's buttons are not held by it.
@MainActor
@Observable
public final class TVHelperGuide {
    /// How long the helper's copy is trusted before the helper is asked again whether it changed.
    public nonisolated static let checkInterval: TimeInterval = 3600

    /// The line on screen while the guide is fetched, and as each type of it is.
    public nonisolated static let line = "番組表を取得中（テレビ）"

    /// The helper's silence while the television answers beside it: the helper is not running there. A television
    /// that restarted itself was seen to leave it so, and opening it once on the television starts it again. Said
    /// only then: with the television not answering either, the reader may be away from home, and the helper's
    /// silence is said as it always was.
    public nonisolated static let notRunning =
        "テレビは応答していますが、ヘルパーが応答しません。テレビで「RecBridge ヘルパー」を一度開いてください"

    public nonisolated static func line(for broadcasting: String) -> String {
        "番組表を取得中（テレビ: \(Codes.broadcastingLabel[broadcasting] ?? broadcasting)）"
    }

    public let client: TVHelperClient
    /// Whether a registration with the helper is held, for the screens: the token is in a store they cannot watch.
    public private(set) var isRegistered: Bool
    /// When the helper last said what it has, nil before it has or since `forgetTheCheck`.
    public private(set) var lastCheck: Date?
    /// Whether a fetch is out.
    public private(set) var isFetching = false
    /// The fetch that is out, which whoever asks meanwhile waits for.
    @ObservationIgnored private var fetching: Task<String?, Never>?

    public init(client: TVHelperClient) {
        self.client = client
        isRegistered = client.isRegistered
    }

    /// Registers with the helper by the code the television shows, under `label`, what the helper lists this
    /// device as; first making sure that what answers is the helper. Says what went wrong, or nil.
    public func register(code: String, label: String) async -> String? {
        do {
            try await client.probe(timeout: 5)
            try await client.pair(code: code, label: label)
        } catch {
            return Self.said(error)
        }
        isRegistered = true
        return nil
    }

    /// Forgets the registration. The helper keeps listing this device until it is taken off its list on the
    /// television.
    public func forgetRegistration() {
        client.forgetRegistration()
        isRegistered = false
    }

    /// Whether the helper is to be asked again: never asked, or not within `checkInterval`.
    public func isDue(at now: Date = Date()) -> Bool {
        lastCheck.map { now.timeIntervalSince($0) >= Self.checkInterval } ?? true
    }

    /// Asks the helper again at the next fetch however lately it was asked: for a guide taken over from the other
    /// device, whose marks have been forgotten.
    public func forgetTheCheck() {
        lastCheck = nil
    }

    /// Fetches the television's guide into `store`: the types the helper has newer copies of than the cache was
    /// filled from, or that the cache holds no programmes of; or every type the helper has programmes of
    /// (`every`), as 番組表を更新 asks. CS4K is left out either way (`GuideRefresh.broadcastingTypes`). Says
    /// what went wrong, or nil. One fetch at a time: asked while one is out, it waits for that one and says what
    /// it said.
    ///
    /// Under a line on the host of `link`, the television's, which says each type as it is fetched. The check
    /// is noted once the helper has said what it has (`lastCheck`), and not when it could not be asked. A type
    /// that fails is passed over and said, as the recorder's are (`RecorderDriver.guideFailed`), and its mark is
    /// left, so that it is fetched again; silence ends the fetch and is said after them. `stored` is called with
    /// each type once it is in the cache.
    @discardableResult
    public func fetch(every: Bool = false, into store: GuideStore, on link: DeviceLink?,
                      stored: @escaping @MainActor @Sendable (String) async -> Void) async -> String? {
        if let fetching { return await fetching.value }
        let fetch = Task { @MainActor in
            guard let link else {
                return await self.fetchTypes(every: every, into: store, host: nil, line: nil,
                                             televisionAnswers: { false }, stored: stored)
            }
            // The host read once, as the line's own is.
            let host = link.owner
            return await link.underALine(Self.line) { line in
                await self.fetchTypes(every: every, into: store, host: host, line: line,
                                      televisionAnswers: { link.session.connected }, stored: stored)
            }
        }
        fetching = fetch
        isFetching = true
        let said = await fetch.value
        fetching = nil
        isFetching = false
        return said
    }

    private func fetchTypes(every: Bool, into store: GuideStore, host: (any LinkHost)?, line: Activities.Token?,
                            televisionAnswers: @MainActor () -> Bool,
                            stored: @escaping @MainActor @Sendable (String) async -> Void) async -> String? {
        let info: TVHelperInfo
        do {
            info = try await client.info()
        } catch TVHelperError.transport {
            return Self.silence(televisionAnswers: televisionAnswers())
        } catch {
            return Self.said(error)
        }
        var types = GuideRefresh.broadcastingTypes.filter { (info.types[$0]?.programs ?? 0) > 0 }
        if !every {
            let held = (try? await store.counts()) ?? [:]
            var behind: [String] = []
            for broadcasting in types {
                let changed = info.types[broadcasting]?.changedAt ?? Date()
                let filledFrom = try? await store.helperChanged(broadcasting: broadcasting)
                if filledFrom.map({ changed > $0 }) ?? true || (held[broadcasting]?.programs ?? 0) == 0 {
                    behind.append(broadcasting)
                }
            }
            types = behind
        }
        lastCheck = Date()
        guard !types.isEmpty else { return nil }
        let outcome = await GuideRefresh.run(client: client, store: store, types: types, onType: { broadcasting in
            if let line { host?.updateActivity(line, to: Self.line(for: broadcasting)) }
            return true
        }, onStored: stored)
        for broadcasting in outcome.answered {
            try? await store.noteHelperChanged(broadcasting: broadcasting,
                                               at: info.types[broadcasting]?.changedAt ?? Date())
        }
        var lines = RecorderDriver.guideFailed(outcome.failed)
        if outcome.stopped == .silent { lines.append(Self.silence(televisionAnswers: televisionAnswers())) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The helper's silence in words: `notRunning` where the television answers, its own sentence otherwise.
    static func silence(televisionAnswers: Bool) -> String {
        televisionAnswers ? notRunning : TVHelperError.transport("").explanation
    }

    private static func said(_ error: any Error) -> String {
        (error as? any DeviceError)?.explanation ?? String(describing: error)
    }
}
