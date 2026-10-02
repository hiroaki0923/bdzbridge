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

        public init() {}
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
    /// and is thrown at once: a recorder that has stopped answering will not answer for the next type, and
    /// each file asked of it costs a two-minute timeout.
    ///
    /// Cancellation is looked at before each type. The request under way is finished rather than abandoned
    /// (see `SerialQueue`), and each type is stored in one transaction, so stopping there leaves nothing half
    /// written. Only the overnight run is meant to be stopped this way.
    ///
    /// `onType` is called on the main actor as each type starts, and `onStored` once its programmes and logos
    /// are in the cache, for the screen to show them without waiting for the rest.
    public static func run(client: some GuideSource, store: GuideStore, types: [String] = broadcastingTypes,
                           onType: (@MainActor @Sendable (String) -> Void)? = nil,
                           onStored: (@MainActor @Sendable (String) async -> Void)? = nil) async throws -> Outcome {
        var outcome = Outcome()
        for broadcasting in types {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            await onType?(broadcasting)
            do {
                guard let services = try await client.guide(broadcasting) else {
                    try await store.noteNoGuide(broadcasting: broadcasting)
                    outcome.answered.append(broadcasting)
                    continue
                }
                outcome.stored += try await store.replace(services, broadcasting: broadcasting)
                outcome.answered.append(broadcasting)
                do {
                    if let logos = try await client.logos(broadcasting) {
                        try await store.replaceLogos(logos, broadcasting: broadcasting)
                    }
                } catch let error as any DeviceError where error.failure == .silent {
                    throw error
                } catch {
                    // The logos are only looks, and the programmes are in: the type keeps the logos it had.
                }
                await onStored?(broadcasting)
            } catch let error as any DeviceError where error.failure == .silent {
                throw error
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

    /// The broadcasting types the recorder has not been asked for since that rebuild, or never: the ones
    /// worth fetching again. Each type by its own time: by the newest, a type that failed while the others
    /// came in would count as fresh; by the oldest, one the recorder cannot give would have every connect
    /// fetch all four. A type it answered with no file for is marked as asked (`GuideCounts.checked`).
    public static func staleTypes(_ counts: [String: GuideCounts], now: Date = Date(),
                                  types: [String] = broadcastingTypes) -> [String] {
        let rebuilt = lastRebuild(before: now)
        return types.filter { broadcasting in
            guard let answered = counts[broadcasting]?.lastAnswered else { return true }
            return answered < rebuilt
        }
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
