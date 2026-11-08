import Foundation
import RecorderKit

/// What `AppModel` reaches beyond itself: where it keeps its settings and its database, how its requests get
/// to the recorder, which network it takes itself to be on, what it does on that network and on the
/// screen of its own accord, and what a search for a recorder and a television looks round, asks through and
/// pauses by.
///
/// The app has one of these, `app`, and passes no other. It is here for the unit tests (`BDBridgeTests`),
/// which make models of their own: settings in a suite they throw away, a database in a folder of their own,
/// an invented recorder for a transport -- the demo's, or one that never answers -- a network that
/// changes when the test says so, and a Wi-Fi of invented addresses for a search to go through.
///
/// It is also how the model reaches what only the platform has -- the Keychain, notifications, a background
/// task, VoiceOver, a watcher of the network, UIKit's drawing -- so that the model itself names none of them:
/// the app's are in `SurroundingsApp.swift`. The overnight run, the demo's own switch and the screens still
/// read the shared defaults for themselves.
struct Surroundings {
    /// Where the address, the MAC and the screens' choices are kept, and whether the demo is on.
    var defaults: UserDefaults
    /// The folder the guide databases go in, the real recorder's and the demo's.
    var folder: () throws -> URL
    /// How requests reach the recorder at an address. Not the demo's: that recorder is the model's own, kept
    /// for as long as the demo lasts, since it remembers what is done to it.
    var transport: (_ host: String) -> any HTTPTransport
    /// Which network this device is on, as far as whether to try the recorder again goes
    /// (`AppModel.networkChanged`).
    var networkSignature: () -> String
    /// Whether the model may put anything on the local network by itself besides its requests to the
    /// recorder -- the magic packet and the search of the subnet for a recorder the router has moved -- and
    /// whether it watches for the network changing. The tests run on somebody's network, where none of that may
    /// happen. The looks at the local network permission are not under this: an address given for a
    /// television's (`localNetworkAccess`) and the links' (`linkIsBlocked`), which a test answers itself.
    var reachesTheLAN: Bool
    /// Whether the model asks the system about notifications. The dialog waits for a tap, and in a test
    /// there is nobody to give it.
    var asksAboutNotifications: Bool
    /// How long the recorder's client pauses before sending again what was answered 503. A test has no seconds
    /// to spend on it: that the request is sent again is RecorderKit's to test.
    var busyRetryDelay: ClosedRange<Double> = 0.5...1
    /// How long a write to the cache waits for another connection's: five seconds, shortened only by a test that
    /// holds the lock on purpose and has no reason to wait them out.
    var storeBusyTimeoutMilliseconds: Int32 = 5000
    /// How long after an attach found the recorder's USB slot answering no disk, while one was known, the slot is
    /// read again: the driver's minute, shortened only by a test, which has no minute to wait.
    var slotReadAgainAfter: Duration = RecorderDriver.slotReadAgainAfter
    /// How long the USB slot is waited for before something that names it is sent while the slot has not answered
    /// the disk known since the recorder last answered: the driver's ten seconds, shortened only by a test.
    var slotSettling: SlotSettling = .afterAWaking
    /// How long a request to the recorder waits at most while another of the link's clients has one out at the same
    /// address: its own timeout, shortened only by a test, which holds requests for as long as it likes. That a
    /// request waits is RecorderKit's to test.
    var wireWaitLimit: TimeInterval?
    /// How requests reach the television at an address: a transport that keeps no cookies of its own, since
    /// the client sends its registration's by hand. Nothing answers unless a test says otherwise.
    var tvTransport: (_ host: String) -> any HTTPTransport = { _ in NoTelevision() }
    /// Where the television's registration is kept: the Keychain in the app, memory in a test.
    var tvCredentials: any TVCredentialStore = MemoryTVCredentials()
    /// Where the token of the helper on the television is kept, as `tvCredentials` is the television's own.
    var tvHelperTokens: any TVHelperTokenStore = MemoryTVHelperToken()
    /// How long a television's list of recordings that may still be coming is waited for: the driver's three
    /// minutes, shortened only by a test.
    var tvTitlesWait: TVTitlesWait = .afterAStart
    /// The one look at the local network permission an address given for a television has when nothing
    /// answered there, and the wait for the permission when the look says the system keeps the app off
    /// (`AppModel.findTV`): the links' own look and wait in the app (`LocalNetwork.access`,
    /// `LocalNetwork.waitForAccess`), aimed at that address. Allowed at once unless a test says otherwise, so
    /// that a test can say what each comes to, apart from the links' (`linkIsBlocked`).
    var localNetworkAccess: @Sendable (_ host: String) async -> LocalNetwork.Access? = { _ in .allowed }
    var waitForLocalNetwork: @Sendable (_ host: String) async -> LocalNetwork.Access = { _ in .allowed }
    /// The links' own look at the local network permission, after a device of either kind was silent at its
    /// address, and their hosts' wait for the permission when the look says the system keeps the app off
    /// (`AppModel.linkEnvironment`, `RecorderHost.waitForPermission`, and the television's): `LocalNetwork.access`
    /// and `LocalNetwork.waitForAccess` in the app, apart from the look and the wait of an address given for a
    /// television above. Not in the way and allowed at once unless a test says otherwise. Never looked at in the
    /// demo.
    var linkIsBlocked: @Sendable (_ host: String) async -> Bool = { _ in false }
    var waitForTheLinksPermission: @Sendable (_ host: String) async -> LocalNetwork.Access = { _ in .allowed }
    /// The interfaces a search for a recorder and a television looks round (`AppModel.scanForDevices`): the
    /// Wi-Fi's in the app. None unless a test puts its phone on one, and a search then says there is no Wi-Fi
    /// and asks nobody. Never read in the demo, whose search asks the demo's own devices.
    var lanInterfaces: () -> [LocalNetwork.Interface] = { [] }
    /// What one search sends its requests through, to every address of the subnet, both kinds: made anew for
    /// each look, as the app's session is, a session that keeps no cookies and follows no redirect, as every
    /// session that asks a television does. Nobody answers unless a test says otherwise. Never made in the demo.
    var scanTransport: () -> any HTTPTransport = { NoRecorderAnywhere() }
    /// How a search lets time go by between one single request and the next, after a look through the subnet
    /// that was turned away (`AppModel.scanForDevices`): for as long as the search says, a second, in the
    /// app. Not at all, unless a test holds the search there.
    var scanPause: @Sendable (Duration) async -> Void = { _ in }
    /// Where a search writes what it did, a line at a time, for reading afterwards: the system's log in the
    /// app (`ScanLog`, which says what a line may hold). Nowhere, unless a test keeps the lines to look at.
    var scanLog: @MainActor (String) -> Void = { _ in }
    /// What the model has the system post or take away of its own accord about notifications, and where the
    /// reader stands on them: the system's own in the app (`Notify`). Asked only while
    /// `asksAboutNotifications`, and nothing at all unless a test says otherwise.
    var notifications = Notifications()
    /// The time the system gives a step of a bulk job to finish once the reader has left the app
    /// (`RecorderHost.holdAStep`): a background task in the app. Begun with what to do should that time run out,
    /// it hands back how to end it, or nil when the system gives none. A test's is given at once and has nothing
    /// to end.
    var holdTime: @MainActor (_ ranOut: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)? = { _ in {} }
    /// Says a sentence to a reader whose screen reader is on, for words that appear away from where their focus
    /// is (`AppModel.report`): an announcement to VoiceOver in the app. Nothing in a test.
    var announce: @MainActor (String) -> Void = { _ in }
    /// Watches the network underneath, calling back at each change it reports, for as long as what it hands
    /// back is kept (`AppModel.watchNetwork`): `NWPathMonitor` in the app. Asked only while `reachesTheLAN`.
    var watchTheNetwork: (_ reported: @escaping @Sendable () -> Void) -> AnyObject? = { _ in nil }
    /// The logo the demo's guide shows for a station, from the station's two characters and its place in the
    /// line-up (`DemoLineUp.seed`): a coloured tile drawn in the app (`DemoData.logo`). None in a test.
    var demoLogo: @MainActor (_ text: String, _ index: Int) -> Data? = { _, _ in nil }
}

/// What the model has the system do about notifications (`Surroundings.notifications`), a step at a time:
/// the app's are `Notify`'s. Nothing, unless a test or the app says otherwise.
struct Notifications: Sendable {
    /// Where the reader stands on them, for the settings to say.
    var permission: @Sendable () async -> NotificationPermission = { .notDetermined }
    /// Permission to post quietly, the first time and only then, with no dialog (`Notify.allowQuietly`).
    var allowQuietly: @Sendable () async -> Void = {}
    /// The system's dialog, unless the reader has answered it (`Notify.askIfNeeded`).
    var askIfNeeded: @Sendable () async -> Void = {}
    /// The recorder's warning of reservations not yet there, posted or taken away (`Notify.recorder`).
    var recorder: @Sendable (_ notYet: String?, _ withdraws: Bool) async -> Void = { _, _ in }
    /// What is to go of what the runs with no screen told of the television (`Notify.withdrawTelevision`).
    var withdrawTelevision: @Sendable (NoScreenNotices) -> Void = { _ in }
    /// The television's warning of reservations not yet there, taken away (`Notify.withdrawTelevisionNotYet`).
    var withdrawTelevisionNotYet: @Sendable () -> Void = {}
}

/// Where the reader stands on the app's notifications, as the settings say it: not asked yet, refused, allowed,
/// allowed for a while, or allowed quietly into Notification Centre without having been asked. `unknown` is a
/// standing the system has that none of these is.
enum NotificationPermission: Sendable {
    case notDetermined
    case denied
    case authorized
    case ephemeral
    case provisional
    case unknown
}

/// What a search reaches where no subnet has been given: nobody, at any address.
actor NoRecorderAnywhere: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw RecorderError.transport("Nobody here.")
    }
}

/// What a television's link reaches where no television has been given: silence.
actor NoTelevision: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw RecorderError.transport("No television here.")
    }
}
