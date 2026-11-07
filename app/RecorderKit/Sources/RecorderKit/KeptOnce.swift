import Foundation

/// Where something is kept between runs: the platform's own store of settings, under a key -- `UserDefaults` in
/// the iOS app. Handed to a run's own task, so it is to be safe to use from any of them.
public protocol KeptData: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeData(forKey key: String)
}

/// What the runs with no screen have told once of one device (`ToldOnce`), kept as JSON under its key in the store
/// handed in. Every reader and writer of the two keys reads and keeps it through one of these, so that each does
/// it the same way: the runs with no screen, whether or not a notification could be heard; the screens, once
/// none of the reservations warned of waits to go; and what forgets it -- for the recorder, the cache made over to
/// another recorder; for the television, one registered or taken away.
public struct KeptOnce: Sendable {
    /// The keys the two devices' are kept under, the recorder's apart from the television's.
    public static let recorderKey = "recorderTold"
    public static let televisionKey = "tvTold"

    public let key: String
    public let store: any KeptData

    public init(key: String, store: any KeptData) {
        self.key = key
        self.store = store
    }

    /// The recorder's.
    public static func recorder(in store: any KeptData) -> KeptOnce {
        KeptOnce(key: recorderKey, store: store)
    }

    /// The television's.
    public static func television(in store: any KeptData) -> KeptOnce {
        KeptOnce(key: televisionKey, store: store)
    }

    /// What is kept; nil when nothing is, or what is cannot be read.
    public func read() -> ToldOnce? {
        store.data(forKey: key).flatMap { try? JSONDecoder().decode(ToldOnce.self, from: $0) }
    }

    /// What a run with no screen is handed to read what was told before by: what is kept, or nothing told.
    public var reading: @Sendable () -> ToldOnce {
        { read() ?? ToldOnce() }
    }

    /// Keeps `told` in place of what was; nothing is written when it cannot be put as JSON.
    public func keep(_ told: ToldOnce) {
        if let kept = try? JSONEncoder().encode(told) { store.set(kept, forKey: key) }
    }

    public func forget() {
        store.removeData(forKey: key)
    }
}
