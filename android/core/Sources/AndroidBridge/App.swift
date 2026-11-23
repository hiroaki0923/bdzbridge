#if canImport(Android)
import Android
#endif
import Foundation
import Observation
import RecBridgeModel
import RecorderKit

// What the Android screens reach the app's model through: the iOS app's own `AppModel`, made once for the process
// as the iOS app makes it once, and a window in front of it for each screen. The model is isolated to the main actor
// and observed as SwiftUI observes it, neither of which swift-java can hand to Kotlin as they are (`docs/
// android-port-study.md`), so a window is a plain class: what the reader does goes to the model as an async call,
// and what the screen shows is read as one value, worded as the iOS screen words it, whenever the window says the
// model has moved. The model is not changed for any of this.

/// What Kotlin implements to be told that what a window shows has changed, and so is to be read again. Told nothing
/// more: what can go over that way is numbers, text and truth values, and the value is read instead.
public protocol ScreenListener {
    func changed()
}

/// What Kotlin implements to draw a demo station's logo tile: `text` is the station's two characters, `index` its place
/// in its broadcasting type's line-up, and the PNG is written to the file `path` names. Only numbers and text cross
/// this way, so the picture comes back as a file; nothing is written if the drawing fails, which is no logo.
public protocol TileDrawer {
    func draw(_ text: String, _ index: Int64, _ path: String)
}

/// Where the drawer is kept once Kotlin has handed it over, which is after the model's surroundings were made.
final class Tiles: @unchecked Sendable {
    private let lock = NSLock()
    private var drawer: (any TileDrawer)?
    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    func set(_ drawer: any TileDrawer) { lock.withLock { self.drawer = drawer } }

    /// The tile for `text` at `index`, as the PNG the drawer wrote, or nil with no drawer or no file.
    func logo(_ text: String, _ index: Int) -> Data? {
        guard let drawer = lock.withLock({ drawer }) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "-")
        let file = folder.appendingPathComponent("\(index)-\(name).png")
        try? FileManager.default.removeItem(at: file)
        drawer.draw(text, Int64(index), file.path)
        defer { try? FileManager.default.removeItem(at: file) }
        return try? Data(contentsOf: file)
    }
}

/// The network's watcher on Android: what the model hands to `Surroundings.watchTheNetwork` is kept here, and Android's
/// own watcher (`ConnectivityManager`, in Kotlin) reaches it through `RecBridgeApp.networkChanged`. What the model
/// holds as its watcher is the token, so the reports stop when the model lets go of it, as an iOS monitor's do.
final class NetworkReports: @unchecked Sendable {
    final class Watch: Sendable {
        let reported: @Sendable () -> Void
        init(_ reported: @escaping @Sendable () -> Void) { self.reported = reported }
    }

    private let lock = NSLock()
    private weak var current: Watch?

    /// The model's wish to be told, as the token it keeps.
    func watch(_ reported: @escaping @Sendable () -> Void) -> AnyObject {
        let watch = Watch(reported)
        lock.withLock { current = watch }
        return watch
    }

    /// The network has changed: tells the model, if it is watching.
    func report() {
        lock.withLock { current }?.reported()
    }
}

/// The app: its one model, and the windows of its screens.
public final class RecBridgeApp: Sendable {
    let model: AppModel
    /// The setting the settings screen writes itself, as the iOS screen writes it, and what the app's version is
    /// called, for the settings to say.
    let quality: ChosenQuality
    /// Which view of the recordings is on, and the guide's list or grid and the grid's scale, kept as the iOS screens
    /// keep them.
    let recordingsMode: ShownMode
    let guideChoices: GuideChoices
    /// The minute it is, for the grid.
    let clock: MinuteClock
    let version: String
    let tiles: Tiles
    let network: NetworkReports

    init(model: AppModel, quality: ChosenQuality, recordingsMode: ShownMode, guideChoices: GuideChoices,
         clock: MinuteClock, version: String, tiles: Tiles, network: NetworkReports) {
        self.tiles = tiles
        self.network = network
        self.model = model
        self.quality = quality
        self.recordingsMode = recordingsMode
        self.guideChoices = guideChoices
        self.clock = clock
        self.version = version
    }

    @MainActor private static var opened: RecBridgeApp?

    /// The app's model, made the first time and the same one after that: one model for the process, since each
    /// has its own link to the recorder, which answers one request at a time. `files` is the app's own folder, where
    /// the settings and the guide are kept; `kept`, the folder of its that never leaves the device, where the
    /// television's registration is (`KeptTVCredentials`); `release` and `build`, the app's version and its build,
    /// which the settings say as the model words them (`SettingsWords.version`: `0.1 (1)`).
    public static func open(files: String, kept: String, release: String, build: String) async -> RecBridgeApp {
        await MainActor.run {
            if let opened { return opened }
            let app = made(files: files, kept: kept, version: SettingsWords.version(release: release, build: build))
            opened = app
            return app
        }
    }

    /// A model on `files` and `kept`: what `open` makes once for the process, and each test for itself, which
    /// may give a search's probes longer than the app does (`Surroundings.scanProbeTimeout`).
    @MainActor
    static func made(files: String, kept: String, version: String,
                     scanProbeTimeout: TimeInterval? = nil) -> RecBridgeApp {
        let defaults = WrittenDefaults.android(files: files)
        let tiles = Tiles(folder: URL(fileURLWithPath: files, isDirectory: true)
            .appendingPathComponent("demo-tiles", isDirectory: true))
        let network = NetworkReports()
        var surroundings = Surroundings.android(files: files, kept: kept, defaults: defaults, version: version,
                                                tiles: tiles, network: network)
        if let scanProbeTimeout { surroundings.scanProbeTimeout = scanProbeTimeout }
        let model = AppModel(surroundings: surroundings)
        return RecBridgeApp(model: model, quality: ChosenQuality(defaults), recordingsMode: ShownMode(defaults),
                            guideChoices: GuideChoices(defaults), clock: MinuteClock(), version: version, tiles: tiles,
                            network: network)
    }

    /// Who draws the demo's station tiles. Told before `start`, which seeds the demo's guide when the demo is on.
    public func drawsTiles(_ drawer: some TileDrawer) { tiles.set(drawer) }

    /// The network under the device has changed (an address came or went, the default network was lost): what the
    /// iOS app's `NWPathMonitor` tells the model at each path update. The model looks at the addresses itself and
    /// asks again only if they have changed. Callable from any thread.
    public func networkChanged() { network.report() }

    /// Opens the cache and shows what it holds, and makes the first connect: what every iOS screen awaits first.
    public func start() async {
        await model.start()
    }

    /// 再接続 on a screen with no recorder to talk to, as the model answers it (`AppModel.act(on:)`): it connects again,
    /// and wakes the recorder first if that is what it needs. Nothing while it is held, as the iOS button is then.
    public func connect() async {
        let model = self.model
        await MainActor.run { pressed(!model.holds(.reconnect)) { await model.act(on: .reconnect) } }?.value
    }

    /// The app is on screen, or not. Told at each change, as the iOS app tells its scene's.
    public func activeChanged(_ active: Bool) async {
        await model.activeChanged(to: active)
    }

    /// The app has gone out of sight, which is what makes coming back worth a reconnect.
    public func wentToBackground() async {
        await model.wentToBackground()
    }

    /// The app is back on screen.
    public func returnedToForeground() async {
        await model.returnedToForeground()
    }

    public func devices() async -> DevicesWindow {
        await MainActor.run { DevicesWindow(model) }
    }
    public func guide() -> GuideWindow { GuideWindow(model, choices: guideChoices, clock: clock) }
    public func reservations() async -> ReservationsWindow {
        await MainActor.run { ReservationsWindow(model) }
    }
    public func recordings() async -> RecordingsWindow {
        await MainActor.run { RecordingsWindow(model, mode: recordingsMode) }
    }

    /// The bulk job, wherever the reader happens to be looking: on the recordings' screen and on a programme's page.
    public func job() -> JobWindow { JobWindow(model) }

    /// The recorder's own keyword conditions (おまかせ・まる録): a window of its own, ended as its page closes.
    public func conditions() async -> ConditionsWindow {
        await MainActor.run { ConditionsWindow(model) }
    }

    /// The recordings that look like copies of one broadcast.
    public func duplicates() async -> DuplicatesWindow {
        await MainActor.run { DuplicatesWindow(DuplicatesState(model: model), model: model) }
    }
    public func strip() -> StripWindow { StripWindow(model) }
    /// The strip a sheet or a form has of its own (`recorderActivity(inSheet: true)`), without the demo's line.
    public func sheetStrip() -> StripWindow { StripWindow(model, inSheet: true) }
    /// The words the sheets say alike, as the model has them, for Kotlin to keep (`SheetWordsText`).
    public func sheetWords() -> SheetWordsText { .all }
    /// The settings' words that never change, as the model has them, for Kotlin to keep (`SettingsWordsText`).
    public func settingsWords() -> SettingsWordsText { .all }
    /// The television's words that never change, as the model has them, for Kotlin to keep (`TelevisionWordsText`).
    public func televisionWords() -> TelevisionWordsText { .all }
    /// The guide's and the stations' screen's words that never change, as the model has them, for Kotlin to keep
    /// (`GuideWordsText`).
    public func guideWords() -> GuideWordsText { .all }
    /// The names of the tabs, as the model has them, for Kotlin to keep (`TabWordsText`).
    public func tabWords() -> TabWordsText { .all }
    /// The words of the reservations' list and of the recordings' that never change, as the model has them, for Kotlin
    /// to keep (`ListWordsText`).
    public func listWords() -> ListWordsText { .all }
    public func search() async -> SearchWindow {
        await MainActor.run { SearchWindow(model) }
    }
    public func settings() async -> SettingsWindow {
        await MainActor.run { SettingsWindow(model, quality: quality, version: version) }
    }

    /// Which stations the guide shows and in what order, opened at the broadcasting type the guide is on: from the
    /// settings, from the guide's station menu, or from a guide with every station hidden.
    public func channels() async -> ChannelsWindow {
        await MainActor.run { ChannelsWindow(ChannelsState(broadcasting: model.broadcasting, model: model)) }
    }

    /// The sheet that adds a television at `host` -- one a search found, going straight on to it (`connectAtOnce`),
    /// or an address to type -- or registers with the one added again (`again`).
    public func registerTV(host: String, connectAtOnce: Bool, again: Bool) async -> TVRegisterWindow {
        await MainActor.run {
            TVRegisterWindow(TVRegisterState(model: model, host: host, connectAtOnce: connectAtOnce, again: again))
        }
    }

    /// The same sheet, registering with the television added again: the strip's 登録 and the settings' 登録する.
    public func registerTVAgain() async -> TVRegisterWindow {
        await MainActor.run {
            TVRegisterWindow(TVRegisterState(model: model, host: model.tv?.host ?? "", again: true))
        }
    }

    /// The sheet that registers with the helper on the television added.
    public func registerHelper() async -> HelperRegisterWindow {
        await MainActor.run { HelperRegisterWindow(HelperRegisterState(model: model)) }
    }
}

extension Surroundings {
    /// What the model reaches on Android. The settings go in a file of the app's folder (`WrittenDefaults`), the
    /// television's registration and the helper's token in the folder that never leaves the device (`Kept.swift`).
    /// What only the iOS app has yet -- notifications -- is left as the model's own defaults give it, which do nothing.
    static func android(files: String, kept: String, defaults: WrittenDefaults, version: String, tiles: Tiles,
                         network: NetworkReports) -> Surroundings {
        let folder = URL(fileURLWithPath: files, isDirectory: true)
        let keptFolder = URL(fileURLWithPath: kept, isDirectory: true)
        var android = Surroundings(defaults: defaults, folder: { folder }, transport: { _ in URLSessionTransport() },
                                   networkSignature: LocalNetwork.signature, reachesTheLAN: true,
                                   asksAboutNotifications: false)
        android.tvTransport = { _ in URLSessionTransport.withoutCookies() }
        android.lanInterfaces = LocalNetwork.lanInterfaces
        android.scanTransport = { URLSessionTransport.withoutCookies() }
        android.scanPause = { try? await Task.sleep(for: $0) }
        android.scanLog = { SearchLog.note($0) }
        android.appVersion = { version }
        android.tvCredentials = KeptTVCredentials(folder: keptFolder)
        android.tvHelperTokens = KeptTVHelperToken(folder: keptFolder)
        android.helperLabel = "RecBridge (Android)"
        android.demoLogo = { text, index in tiles.logo(text, index) }
        android.watchTheNetwork = { reported in network.watch(reported) }
        // The step of a bulk job in hand when the reader leaves the app is finished, as on iOS: Swift's main queue
        // is run until its time is ended (`StepsHeld`, `runWhatWaitsOnTheMainQueue`).
        android.holdTime = { _ in
            StepsHeld.shared.begin()
            return { StepsHeld.shared.end() }
        }
        return android
    }
}

/// The model's settings on Android. Foundation keeps none of the shared defaults there, but keeps a suite named by
/// the path of its file -- and writes it out only when told to (`synchronize`), posting nothing when a value changes
/// (`didChangeNotification`). Apple's Foundation writes by itself, so the model, written for it, never tells. This one
/// writes itself out at each change, as the model makes it. Measured on the emulator: without it nothing was written,
/// and a second start read nothing.
final class WrittenDefaults: UserDefaults {
    /// The app's, in `<files>/settings`: one object for the file in the process, made the first time it is asked
    /// for. The screens' model and an overnight run in the same process then read and write the same one, as the iOS
    /// app's share the standard defaults; whether two objects over one file would see each other's changes on Android
    /// has not been looked into, and with one the question does not arise.
    static func android(files: String) -> WrittenDefaults {
        let settings = URL(fileURLWithPath: files, isDirectory: true).appendingPathComponent("settings", isDirectory: true)
        let suite = settings.appendingPathComponent("recbridge").path
        return made.withLock { made in
            if let kept = made[suite] { return kept }
            try? FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
            // A suite is refused only by the name of the global domain, which a path is not.
            let defaults = WrittenDefaults(suiteName: suite)!
            made[suite] = defaults
            return defaults
        }
    }

    /// Each one made, by its suite's path.
    private static let made = Made()

    private final class Made: @unchecked Sendable {
        private let lock = NSLock()
        private var bySuite: [String: WrittenDefaults] = [:]

        func withLock<T>(_ body: (inout [String: WrittenDefaults]) -> T) -> T {
            lock.withLock { body(&bySuite) }
        }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        synchronize()
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        synchronize()
    }

    override func set(_ value: Int, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        synchronize()
    }

    override func set(_ value: Double, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        synchronize()
    }

    override func set(_ value: Float, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        synchronize()
    }

    override func set(_ url: URL?, forKey defaultName: String) {
        super.set(url, forKey: defaultName)
        synchronize()
    }

    override func removeObject(forKey defaultName: String) {
        super.removeObject(forKey: defaultName)
        synchronize()
    }
}

/// What a window shows, kept as the model last made it and told to Kotlin each time it changes. It is made on the main
/// actor, where the model is, through Observation, as SwiftUI reads a view's body: a change to anything `make` read
/// makes it again, the words and all, as the iOS screen's body words them. On Android the main actor runs on the
/// thread that draws, so what a screen shows is kept to what it needs.
final class Watched<Shown: Sendable>: Sendable {
    private let make: @MainActor @Sendable () -> Shown
    @MainActor private var latest: Shown?

    init(_ make: @escaping @MainActor @Sendable () -> Shown) {
        self.make = make
    }

    /// The latest made, or one made now when nothing is watching.
    func read() async -> Shown {
        await MainActor.run { latest ?? make() }
    }

    /// Tells `listener` at once, and each time what `make` read has changed, until the task handed back is
    /// cancelled: never, for a screen, which is the app's for as long as it runs; as it closes, for a sheet.
    /// Observation gathers the changes of one turn of the main actor into one.
    @discardableResult
    func watch(_ listener: some ScreenListener) -> Task<Void, Never> {
        nonisolated(unsafe) let listener = listener
        let make = self.make
        return Task { @MainActor in
            for await shown in Observations(make) {
                latest = shown
                listener.changed()
            }
        }
    }
}

/// The names of the five tabs, as the model words them (`TabWords`), for Kotlin to keep from the model's start.
public struct TabWordsText: Sendable {
    public var guide: String
    public var search: String
    public var reservations: String
    public var recordings: String
    public var settings: String

    static let all = TabWordsText(
        guide: TabWords.guide, search: TabWords.search, reservations: TabWords.reservations,
        recordings: TabWords.recordings, settings: TabWords.settings)
}

/// A title and what is said under it, as an empty screen says them.
public struct Said: Sendable {
    public var title: String
    public var detail: String

    init(_ says: AppModel.ScreenSays) {
        title = says.title
        detail = says.detail ?? ""
    }

    init(_ title: String, _ detail: String = "") {
        self.title = title
        self.detail = detail
    }
}

/// One of a menu's choices: what is kept for it and what it says.
public struct Choice: Sendable {
    public var code: String
    public var label: String
}

/// What a screen with no recorder to talk to says, in the four cases the iOS app tells apart
/// (`AppModel.noRecorderSays`) and in the model's words for each (`AppModel.says`): `kind` is `notAdded` (offer the
/// search), `working` (the recorder's line, with a wait), `blocked` (the local network's permission, with nothing
/// under it: what the iOS screen says there is the way to the switch, the system's, and Android's way to the
/// permission comes with the permission itself) or `notReached` (offer 再接続 and the search). `phones` is set when
/// what went wrong is the phone's own cache (the iOS screen shows a warning triangle then). The search and 再接続 are
/// the model's words, held as the model holds them.
public struct NoRecorder: Sendable {
    public var kind: String
    public var said: Said
    public var phones: Bool
    public var search: Offered
    public var reconnect: Offered
}

/// A button in the model's words, and whether it is held now (`AppModel.Offer`, `AppModel.holds`).
public struct Offered: Sendable {
    public var label: String
    public var held: Bool
}

extension Offered {
    @MainActor init(_ offer: AppModel.Offer, _ model: AppModel) {
        self.init(label: offer.label, held: model.holds(offer))
    }
}

extension NoRecorder {
    @MainActor init(_ model: AppModel) {
        let said = model.noRecorderSays
        let kind = switch said {
        case .notAdded: "notAdded"
        case .working: "working"
        case .blocked: "blocked"
        case .notReached: "notReached"
        }
        var phones = false
        if case .notReached(_, let own) = said { phones = own }
        self.init(kind: kind, said: Said(model.says(said)), phones: phones, search: Offered(.search, model),
                  reconnect: Offered(.reconnect, model))
    }
}

/// Whole seconds since 1970, which is how a time crosses to Kotlin for the screen to compare with its clock.
func seconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }

/// What a search for devices leaves in the system log, as `ScanLog` does on iOS: under the tag `RecBridgeScan`, so that
/// `adb logcat -s RecBridgeScan` shows a search afterwards. The lines are the model's own, counts and codes and words of
/// the app's, never an address or a name. Off Android there is no system log, and nothing is written.
enum SearchLog {
    static let tag = "RecBridgeScan"

    static func note(_ line: String) {
        #if os(Android)
        _ = __android_log_write(Int32(ANDROID_LOG_INFO.rawValue), tag, line)
        #endif
    }
}
