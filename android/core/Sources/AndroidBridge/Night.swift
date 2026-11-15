#if canImport(Android)
import Android
#endif
import Foundation
import RecBridgeModel
import RecorderKit

// The overnight run on Android: at night, with no screen, the recorder is woken, what waits is sent to it and to the
// television, and the guide is fetched, as the iOS app's background task does it. The run is the model's
// (`BackgroundWork.refreshNow(in:)`); what the system calls -- the worker, its schedule, its stop -- is Kotlin's
// (`NightWorker`, Night.kt), and what the run reaches of Android is handed in here.

/// The overnight run, for Kotlin's worker: the model's, handed what it reaches of Android -- the model's own defaults
/// object, the app's folder for the guide, the sessions the screens send through, the television's registration in the
/// folder that stays on the device, and notifications that do nothing, since the Android app posts none yet. One rule
/// is Android's own and comes first: the run goes only on the network of a recorder or a television saved, where it
/// can tell (`mayGo`).
public final class NightRun: Sendable {
    /// The app's folder, by which the rule finds the defaults object the run is handed: the process's one for the file
    /// (`WrittenDefaults.android`).
    private let files: String
    private let surroundings: NoScreenSurroundings
    private let interfaces: @Sendable () -> [LocalNetwork.Interface]
    private let work = Work()

    /// On the app's two folders, as `RecBridgeApp.open` is given them.
    public static func make(files: String, kept: String) -> NightRun {
        NightRun(files: files, kept: kept, interfaces: { LocalNetwork.lanInterfaces() },
                 transport: { _ in URLSessionTransport() }, tvTransport: { _ in URLSessionTransport.withoutCookies() })
    }

    /// With the device's interfaces and the ways to each device handed in, as a test hands its own.
    init(files: String, kept: String, interfaces: @escaping @Sendable () -> [LocalNetwork.Interface],
         transport: @escaping @Sendable (_ host: String) -> any HTTPTransport,
         tvTransport: @escaping @Sendable (_ host: String) -> any HTTPTransport) {
        let folder = URL(fileURLWithPath: files, isDirectory: true)
        let keptFolder = URL(fileURLWithPath: kept, isDirectory: true)
        self.files = files
        self.interfaces = interfaces
        surroundings = NoScreenSurroundings(
            defaults: WrittenDefaults.android(files: files), folder: { folder }, transport: transport,
            tvTransport: tvTransport, tvCredentials: KeptTVCredentials(folder: keptFolder), notifications: Notifications())
    }

    /// When the next run is to be asked for, in whole seconds since 1970: the next 02:00 by the model's rule
    /// (`BackgroundWork.nextNightlyRun`), soon after the recorder has rebuilt its guide files.
    public static func nextRun() -> Int64 { seconds(BackgroundWork.nextNightlyRun()) }

    /// Runs it, unless it was stopped first, and hands back whether a guide was stored. The run is a task of its own,
    /// for `stop` to cancel: swift-java's call hands nothing of Kotlin's cancelling on to Swift.
    public func run() async -> Bool {
        let files = files, interfaces = interfaces, surroundings = surroundings
        let task = work.begin {
            Task {
                guard NightRun.mayGo(in: WrittenDefaults.android(files: files), on: interfaces()) else { return false }
                return await BackgroundWork.refreshNow(in: surroundings)
            }
        }
        return await task?.value ?? false
    }

    /// The system has stopped the worker: the run's task is cancelled, which is what the model's rules for a run whose
    /// time is up look at, between one step and the next. Not waited for: the worker ends at once, as the iOS app
    /// completes its task without waiting.
    public func stop() { work.stop() }

    /// Android's own rule, the run's first step: it goes only while this device is on the network of a recorder or a
    /// television saved, which is the home's. WorkManager can be told to wait for Wi-Fi, but not for which one. Either
    /// saved address lets it go (`onTheNetwork`). With neither, the run ends there: nothing is opened, no packet is
    /// sent, nothing is written.
    static func mayGo(in defaults: UserDefaults, on interfaces: [LocalNetwork.Interface]) -> Bool {
        [DefaultsKey.recorderHost, DefaultsKey.tvHost].contains { key in
            defaults.string(forKey: key).map { onTheNetwork($0, of: interfaces) } ?? false
        }
    }

    /// An IPv4 address is on the network when it is on that of one of `interfaces`, by that interface's mask. Any other
    /// address saved -- a name, an IPv6 address -- cannot be placed without asking somebody, and goes, as the iOS run
    /// goes whenever it has a connection: a rule that cannot tell must not be the one that stops every night for good.
    /// An empty one is none saved.
    static func onTheNetwork(_ host: String, of interfaces: [LocalNetwork.Interface]) -> Bool {
        guard !host.isEmpty else { return false }
        guard let address = packed(host) else { return true }
        return interfaces.contains { interface in
            guard let own = packed(interface.address), let mask = packed(interface.netmask) else { return false }
            return own & mask == address & mask
        }
    }

    /// A dotted IPv4 address as a number, as RecorderKit reads the interfaces' own; nil for anything else.
    private static func packed(_ dotted: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, dotted, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }
}

/// The run's task, kept for `stop`, and whether it was stopped before it began.
private final class Work: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Bool, Never>?
    private var stopped = false

    /// The task `make` makes, kept; nil, with nothing made, once stopped.
    func begin(_ make: () -> Task<Bool, Never>) -> Task<Bool, Never>? {
        lock.withLock {
            guard !stopped else { return nil }
            let made = make()
            task = made
            return made
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            task?.cancel()
        }
    }
}
