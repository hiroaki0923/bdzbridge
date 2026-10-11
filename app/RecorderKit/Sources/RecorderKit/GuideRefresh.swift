import Foundation

/// Fetching the broadcasting types' guides and logos into the cache. One implementation for the screens and
/// the overnight run, which is why it lives here rather than in the app -- the same reason `PendingQueue` does.
public enum GuideRefresh {
    /// The types the app keeps. `Codes` knows CS4K as well, which the app does not fetch.
    public static let broadcastingTypes = ["td", "bs", "cs", "bs4k"]

    public struct Outcome: Sendable, Equatable {
        /// How many programmes were stored, over every type.
        public var stored = 0
        /// The types the recorder answered for: with a guide, which is now in the cache, or with none to give,
        /// which is noted (`GuideStore.noteNoGuide`).
        public var answered: [String] = []
        /// The types that could not be fetched or stored, in the order they were tried. What the cache held
        /// for them is left as it was, and nothing marks them fetched, so the next refresh asks for them again.
        public var failed: [Failure] = []
        /// Set when the caller's task was cancelled, and the types after the one under way were left.
        public var cancelled = false
        /// Why it ended before its types did, nil when it did not. The rest is what came before: the types
        /// answered and failed until then, and what was stored of them.
        public var stopped: Stop?

        public init() {}
    }

    /// Why a refresh ended before its types did.
    public enum Stop: Sendable, Equatable {
        /// The recorder stopped answering, over a type's guide or over its logos.
        case silent
        /// The guide is no longer for the recorder it was being fetched from: the cache has been made over to
        /// another recorder and took nothing of what came for the last one (`GuideStore.replace`), or whoever
        /// asked said before a type not to go on (`onType`). The write that was refused changed nothing.
        case letGo
    }

    public struct Failure: Sendable, Equatable {
        public var broadcasting: String
        /// Why, in words for the reader.
        public var reason: String
    }

    /// Fetches `types` in turn and replaces what the cache holds for each.
    ///
    /// A type that fails is passed over and the next one is tried. The recorder answers 500 for a file it
    /// has not built yet -- after a restart or a channel scan, until the small hours. Silence is the exception
    /// and ends the refresh at once (`Outcome.stopped`), with what came before it handed back: a recorder that
    /// has stopped answering will not answer for the next type, and each file asked of it costs a two-minute
    /// timeout.
    ///
    /// Cancellation is looked at before each type. The request under way is finished rather than abandoned
    /// (see `SerialQueue`), and each type is stored in one transaction, so stopping there leaves nothing half
    /// written. Only the overnight run is meant to be stopped this way.
    ///
    /// A guide goes only into the cache of the recorder it was fetched from. `recorder` is the one `client`
    /// asks, as it described itself to whoever asks for the refresh, and is handed on with everything written
    /// (`GuideStore.replace`, `noteNoGuide`, `replaceLogos`): once the cache is another recorder's -- made
    /// over while a file was out -- it takes nothing, and the refresh ends there (`Stop.letGo`), the files'
    /// server naming no recorder and the rest being no more this cache's than that one. The screens and the
    /// overnight run always hand one; nil asks nothing, for a test's cache.
    ///
    /// `onType` is called on the main actor as each type starts, and says whether to go on: a caller that
    /// knows the recorder to have been let go of since ends the refresh before another file is asked for
    /// (`Stop.letGo`). `onStored` is called once a type's programmes and logos are in the cache, for the
    /// screen to show them without waiting for the rest.
    public static func run(client: some GuideSource, store: GuideStore, from recorder: RecorderDescription? = nil,
                           types: [String] = broadcastingTypes,
                           onType: (@MainActor @Sendable (String) -> Bool)? = nil,
                           onStored: (@MainActor @Sendable (String) async -> Void)? = nil) async -> Outcome {
        var outcome = Outcome()
        for broadcasting in types {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            if let onType, await !onType(broadcasting) {
                outcome.stopped = .letGo
                break
            }
            do {
                guard let services = try await client.guide(broadcasting) else {
                    try await store.noteNoGuide(broadcasting: broadcasting, from: recorder)
                    outcome.answered.append(broadcasting)
                    continue
                }
                outcome.stored += try await store.replace(services, broadcasting: broadcasting, from: recorder)
                outcome.answered.append(broadcasting)
                do {
                    if let logos = try await client.logos(broadcasting) {
                        try await store.replaceLogos(logos, broadcasting: broadcasting, from: recorder)
                    }
                } catch let error as any DeviceError where error.failure == .silent {
                    throw error
                } catch is CacheIsAnothers {
                    throw CacheIsAnothers()
                } catch {
                    // The logos are only looks, and the programmes are in: the type keeps the logos it had.
                }
                await onStored?(broadcasting)
            } catch let error as any DeviceError where error.failure == .silent {
                outcome.stopped = .silent
                break
            } catch is CacheIsAnothers {
                outcome.stopped = .letGo
                break
            } catch {
                outcome.failed.append(Failure(broadcasting: broadcasting, reason: reason(for: error)))
            }
        }
        return outcome
    }

    /// When the recorder last built its guide files again, which it does in the small hours: the most recent
    /// one o'clock in the morning, its own time. A cache from before that is behind what the recorder would
    /// hand over now.
    public static func lastRebuild(before now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let previous = calendar.nextDate(after: now, matching: DateComponents(hour: 1, minute: 0),
                                         matchingPolicy: .nextTime, direction: .backward)
        return previous ?? now.addingTimeInterval(-24 * 3600)
    }

    /// The next 02:00 in the recorder's own time zone, which the overnight run is asked for. The box rebuilds
    /// its guide files around 00:49.
    public static func nextNightlyRun(after now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let next = calendar.nextDate(after: now, matching: DateComponents(hour: 2, minute: 0),
                                     matchingPolicy: .nextTime)
        return next ?? now.addingTimeInterval(6 * 3600)
    }

    /// The broadcasting types the recorder has not been asked for since that rebuild, or never: the ones
    /// worth fetching again. Each type by its own time: by the newest, a type that failed while the others
    /// came in would count as fresh; by the oldest, one the recorder cannot give would have every connect
    /// fetch all four. A type it answered with no file for is marked as asked (`GuideCounts.checked`).
    public static func staleTypes(_ counts: [String: GuideCounts], now: Date = Date(),
                                  types: [String] = broadcastingTypes) -> [String] {
        staleTypes(counts, since: lastRebuild(before: now), types: types)
    }

    /// The same by any moment in place of the last rebuild: the types the recorder has not been asked for and
    /// answered since `moment`, or never. A type whose mark is of that very moment counts as answered since.
    /// The marks are kept to the whole second (`RecorderTime.format`), so a moment that is to be told from a
    /// mark written just after it is taken to the whole second as well (`toTheSecond`).
    public static func staleTypes(_ counts: [String: GuideCounts], since moment: Date,
                                  types: [String] = broadcastingTypes) -> [String] {
        types.filter { broadcasting in
            guard let answered = counts[broadcasting]?.lastAnswered else { return true }
            return answered < moment
        }
    }

    /// `moment` as a mark of the cache would hold it (`GuideStore.noteNoGuide`): to the whole second.
    static func toTheSecond(_ moment: Date) -> Date {
        RecorderTime.parse(RecorderTime.format(moment)) ?? moment
    }

    static func reason(for error: any Error) -> String {
        switch error {
        case let error as any DeviceError: error.explanation
        case let error as SqliteError: error.explanation
        case is GuideError: "レコーダーから受け取った番組表ファイルを読み取れませんでした"
        default: String(describing: error)
        }
    }
}
