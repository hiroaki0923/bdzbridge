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
        /// Set when the caller's task was cancelled, and what came after the file under way was left: the
        /// types after it, and its own type's logos where it was that type's guide.
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
        /// Whoever asked for the refresh would not have it made once its turn had come (`OnTurn.turnedAway`),
        /// nothing having been asked for, or would not have it go on to its next file (`beforeAFile`): why, in
        /// the asker's own words, for the asker to say, or nil where the asker has nothing to say of it. Not
        /// that the recorder was let go of, which is `letGo`.
        case turnedAway(String?)
    }

    /// What whoever asked for a refresh says once its turn has come
    /// (`run(asked:onTurn:beforeAFile:onType:onStored:)`).
    enum OnTurn: Sendable {
        /// Fetch: the files are asked of `client`, what comes goes into `store`, and `from` is the recorder
        /// `client` asks, as it described itself -- the three `run(client:store:from:types:onType:onStored:)`
        /// is handed.
        case fetch(client: any GuideSource, store: GuideStore, from: RecorderDescription?)
        /// The refresh is not to be made after all, and why (`Stop.turnedAway`). Nil where whoever asked has
        /// nothing to say of it: the overnight run, which tells nobody of a guide it did not ask for. The
        /// screens' step has a sentence whenever it turns a refresh away once the turn has come, and says nil
        /// only of a refresh that is out and not to go on (`beforeAFile`), with this same value.
        case turnedAway(String?)
    }

    public struct Failure: Sendable, Equatable {
        public var broadcasting: String
        /// Why, in words for the reader.
        public var reason: String
    }

    /// The one turn there is for fetching the guide, in the whole process (`run`).
    private static let turn = Turn()

    /// Fetches `types` in turn and replaces what the cache holds for each.
    ///
    /// One refresh at a time, whoever asks and of whichever client: the screens and the overnight run each
    /// have a client and a connection to the cache of their own, in one process when the system wakes the app
    /// for the night while the reader has it open, and a client's own queue keeps apart only what is asked of
    /// that client. Two refreshes asked together would ask the recorder for the same files at once. So a
    /// refresh waits its turn behind one that is out (`Turn`), and is run in the task that asked for it, as
    /// before: it is a wait, and not a queue's task, since cancellation is looked at here (below). Which types
    /// to fetch can be left to be judged once the turn has come
    /// (`run(asked:onTurn:beforeAFile:onType:onStored:)`), by what the refresh before it left in the cache,
    /// and whoever asks can be asked there first whether the refresh is still to be made, and through which
    /// client, and before each file after the first whether it is to go on.
    ///
    /// A type that fails is passed over and the next one is tried. The recorder answers 500 for a file it
    /// has not built yet -- after a restart or a channel scan, until the small hours. Silence is the exception
    /// and ends the refresh at once (`Outcome.stopped`), with what came before it handed back: a recorder that
    /// has stopped answering will not answer for the next type, and each file asked of it costs a two-minute
    /// timeout.
    ///
    /// Cancellation is looked at before each file: before each type, and before each type's logos, which
    /// follow its guide. The request under way is finished rather than abandoned (see `SerialQueue`), and each
    /// type is stored in one transaction, so stopping there leaves nothing half written: a type whose guide
    /// was the file under way is in the cache with the logos it had, and is reported as stored (`onStored`).
    /// Only the overnight run is meant to be stopped this way; the screens' step fetches in a task of its own
    /// that nothing cancels (`RecorderDriver.refreshGuide`). The wait for the turn is not cut short by it, and
    /// the first look comes after that wait: a refresh cancelled while it waited asks for no file.
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
        await run(asked: .only(types), onTurn: { .fetch(client: client, store: store, from: recorder) },
                  onType: onType, onStored: onStored)
    }

    /// The same for the types `which` names, judged once the turn has come where that is by the cache's marks
    /// (`GuideAsked`): what a refresh that was out meanwhile has fetched is not fetched again.
    ///
    /// `onTurn` is asked once the turn has come and before the types are judged, and says what the refresh is
    /// fetched through and into, or why it is not to be made after all (`OnTurn`). The wait for the turn can
    /// be as long as the refresh in front: what its asker made sure of before it is worth nothing by then, and
    /// the client it had in hand then may be in hand no longer. So the screens' step makes sure of its
    /// recorder here and not before the wait, and fetches through the client it finds in hand here, into the
    /// cache and of the recorder it finds with it (`RecorderDriver.refreshGuide`). A refresh ended there has
    /// asked for nothing and gives its turn back (`Stop.turnedAway`). The overnight run has no link to make
    /// sure of, and fetches with what it came with; what it looks at here is what it looked at before the
    /// wait, its own task and whose cache it is by now (`RecorderDriver.refreshWithNoScreen`).
    ///
    /// `beforeAFile` is called on the main actor before each file after the first that is asked for -- before
    /// each type after the first, ahead of `onType`, and before each type's logos, once its programmes are in
    /// the cache -- with the client the files are asked of, and says what the refresh ends there with, why
    /// included where there is something to say (`Stop.turnedAway`), or nil for it to go on: a refresh is as
    /// many requests as it has files, a file of the guide takes its time, and what was made sure of before
    /// the first is not what stands before the last. The screens' step makes sure of its recorder there as a
    /// run does before each of its requests (`RecorderDriver.mayGoOn`). A refresh ended there hands back what
    /// came before. Ended before a type's logos, that type is among what was answered for and stored, and is
    /// reported as stored (`onStored`), with the logos it had. The overnight run passes none.
    static func run(asked which: GuideAsked, onTurn: @Sendable () async -> OnTurn,
                    beforeAFile: (@MainActor @Sendable (any GuideSource) async -> Stop?)? = nil,
                    onType: (@MainActor @Sendable (String) -> Bool)? = nil,
                    onStored: (@MainActor @Sendable (String) async -> Void)? = nil) async -> Outcome {
        await turn.take()
        var outcome = Outcome()
        switch await onTurn() {
        case .turnedAway(let why):
            outcome.stopped = .turnedAway(why)
        case .fetch(let client, let store, let recorder):
            outcome = await fetch(await types(which, by: store), client: client, store: store, from: recorder,
                                  beforeAFile: beforeAFile, onType: onType, onStored: onStored)
        }
        await turn.giveBack()
        return outcome
    }

    /// The types a refresh asked for with `which` fetches, judged as it comes to fetch them. A cache whose
    /// marks cannot be read is taken as never answered for.
    static func types(_ which: GuideAsked, by store: GuideStore) async -> [String] {
        switch which {
        case .all: broadcastingTypes
        case .only(let these): these
        case .notAnsweredSince(let moment): staleTypes((try? await store.counts()) ?? [:], since: moment)
        case .whatIsBehind: staleTypes((try? await store.counts()) ?? [:])
        }
    }

    /// The refresh itself, by whoever has the turn.
    private static func fetch(_ types: [String], client: some GuideSource, store: GuideStore,
                              from recorder: RecorderDescription?,
                              beforeAFile: (@MainActor @Sendable (any GuideSource) async -> Stop?)?,
                              onType: (@MainActor @Sendable (String) -> Bool)?,
                              onStored: (@MainActor @Sendable (String) async -> Void)?) async -> Outcome {
        var outcome = Outcome()
        for (index, broadcasting) in types.enumerated() {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            if index > 0, let stop = await beforeAFile?(client) {
                outcome.stopped = stop
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
                if Task.isCancelled {
                    // The programmes are in: the type is reported as stored, with the logos it had.
                    await onStored?(broadcasting)
                    outcome.cancelled = true
                    break
                }
                if let stop = await beforeAFile?(client) {
                    // The programmes are in: the type is reported as stored, with the logos it had.
                    await onStored?(broadcasting)
                    outcome.stopped = stop
                    break
                }
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
