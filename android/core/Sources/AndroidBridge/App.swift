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

/// The app: its one model, and the windows of its screens.
public final class RecBridgeApp: Sendable {
    let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    @MainActor private static var opened: RecBridgeApp?

    /// The app's model, made the first time and the same one after that: one model for the process, since each
    /// has its own link to the recorder, which answers one request at a time. `files` is the app's own folder, where
    /// the settings and the guide are kept; `version` is what the app's version is called (`0.1 (1)`).
    public static func open(files: String, version: String) async -> RecBridgeApp {
        await MainActor.run {
            if let opened { return opened }
            let app = RecBridgeApp(model: AppModel(surroundings: .android(files: files, version: version)))
            opened = app
            return app
        }
    }

    /// Opens the cache and shows what it holds, and makes the first connect: what every iOS screen awaits first.
    public func start() async {
        await model.start()
    }

    /// 再接続: connects again, and wakes the recorder first if that is what it needs.
    public func connect() async {
        await model.connect()
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

    public func devices() -> DevicesWindow { DevicesWindow(model) }
    public func guide() -> GuideWindow { GuideWindow(model) }
    public func reservations() -> ReservationsWindow { ReservationsWindow(model) }
    public func recordings() -> RecordingsWindow { RecordingsWindow(model) }
    public func strip() -> StripWindow { StripWindow(model) }
}

extension Surroundings {
    /// What the model reaches on Android. The settings go in a file of the app's folder (`WrittenDefaults`). What only
    /// the iOS app has yet -- notifications, the network's watcher, the television's registration kept for good, the
    /// demo's logos -- is left as the model's own defaults give it, which do nothing.
    static func android(files: String, version: String) -> Surroundings {
        let folder = URL(fileURLWithPath: files, isDirectory: true)
        let settings = folder.appendingPathComponent("settings", isDirectory: true)
        try? FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        // A suite is refused only by the name of the global domain, which a path is not.
        let defaults = WrittenDefaults(suiteName: settings.appendingPathComponent("recbridge").path)!
        var android = Surroundings(defaults: defaults, folder: { folder }, transport: { _ in URLSessionTransport() },
                                   networkSignature: LocalNetwork.signature, reachesTheLAN: true,
                                   asksAboutNotifications: false)
        android.tvTransport = { _ in URLSessionTransport.withoutCookies() }
        android.lanInterfaces = LocalNetwork.lanInterfaces
        android.scanTransport = { URLSessionTransport.withoutCookies() }
        android.scanPause = { try? await Task.sleep(for: $0) }
        android.appVersion = { version }
        return android
    }
}

/// The model's settings on Android. Foundation keeps none of the shared defaults there, but keeps a suite named by
/// the path of its file -- and writes it out only when told to (`synchronize`), posting nothing when a value changes
/// (`didChangeNotification`). Apple's Foundation writes by itself, so the model, written for it, never tells. This one
/// writes itself out at each change, as the model makes it. Measured on the emulator: without it nothing was written,
/// and a second start read nothing.
final class WrittenDefaults: UserDefaults {
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
/// (`AppModel.noRecorderSays`): `kind` is `notAdded` (offer the search), `working` (the recorder's line, with a
/// wait), `blocked` (the local network's permission) or `notReached` (offer 再接続 and the search).
public struct NoRecorder: Sendable {
    public var kind: String
    public var said: Said
}

extension NoRecorder {
    @MainActor init(_ model: AppModel) {
        switch model.noRecorderSays {
        case .notAdded:
            self.init(kind: "notAdded", said: Said(AppModel.notAdded))
        case .working(let busy):
            self.init(kind: "working", said: Said(busy, AppModel.wakingDetail))
        case .blocked:
            self.init(kind: "blocked", said: Said(LocalNetwork.accessNotAllowed))
        case .notReached(let why, let phones):
            self.init(kind: "notReached", said: Said(AppModel.notReached(why: why, phones: phones)))
        }
    }
}

/// Whole seconds since 1970, which is how a time crosses to Kotlin for the screen to compare with its clock.
func seconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }
