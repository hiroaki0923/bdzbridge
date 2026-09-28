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
    /// has not built yet -- after a restart or a channel scan, until the small hours -- and one such file used
    /// to end the whole refresh: the types after it were not asked for, and a guide whose first type had come
    /// in counted as fresh, so they were not asked for until the next night either. Silence is the exception
    /// and is thrown at once: a recorder that has stopped answering will not answer for the next type, and
    /// each file asked of it costs a two-minute timeout.
    ///
    /// Cancellation is looked at before each type. The request under way is finished rather than abandoned
    /// (see `SerialQueue`), and each type is stored in one transaction, so stopping there leaves nothing half
    /// written. Only the overnight run is meant to be stopped this way; the screens run it where a screen
    /// going away does not cancel it.
    ///
    /// `onType` is called on the main actor as each broadcasting type starts, for the screen to say so, and
    /// `onStored` once its programmes and logos are in the cache, for the screen to show them without waiting
    /// for the rest.
    public static func run(client: RecorderClient, store: GuideStore, types: [String] = broadcastingTypes,
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
                } catch let error as RecorderError where error.unreachable {
                    throw error
                } catch {
                    // The logos are only looks, and the programmes are in: the type keeps the logos it had.
                }
                await onStored?(broadcasting)
            } catch let error as RecorderError where error.unreachable {
                throw error
            } catch {
                outcome.failed.append(Failure(broadcasting: broadcasting, reason: reason(for: error)))
            }
        }
        return outcome
    }

    static func reason(for error: any Error) -> String {
        switch error {
        case let error as RecorderError: error.explanation
        case let error as SqliteError: error.explanation
        case is GuideError: "レコーダーから受け取った番組表ファイルを読み取れませんでした"
        default: String(describing: error)
        }
    }
}
