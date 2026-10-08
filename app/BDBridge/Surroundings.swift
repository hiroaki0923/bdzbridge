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
/// Only what the tests need is here. The overnight run, the demo's own switch and the screens still read the
/// shared defaults for themselves.
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
    /// recorder -- the magic packet, the probe that looks at the local network permission, the search of the
    /// subnet for a recorder the router has moved -- and whether it watches for the network changing. Off,
    /// the permission is taken as given. The tests run on somebody's network, where none of that may happen.
    /// The look and the wait at an address given for a television are not under this (`localNetworkAccess`).
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
    /// How requests reach the television at an address: a transport that keeps no cookies of its own, since
    /// the client sends its registration's by hand. Nothing answers unless a test says otherwise.
    var tvTransport: (_ host: String) -> any HTTPTransport = { _ in NoTelevision() }
    /// Where the television's registration is kept: the Keychain in the app, memory in a test.
    var tvCredentials: any TVCredentialStore = MemoryTVCredentials()
    /// The one look at the local network permission an address given for a television has when nothing
    /// answered there, and the wait for the permission when the look says the system keeps the app off
    /// (`AppModel.findTV`): the links' own look and wait in the app (`LocalNetwork.access`,
    /// `LocalNetwork.waitForAccess`), aimed at that address. Allowed at once unless a test says otherwise, so
    /// that a test can say what each comes to, where the links' are kept off the network (`reachesTheLAN`).
    var localNetworkAccess: @Sendable (_ host: String) async -> LocalNetwork.Access? = { _ in .allowed }
    var waitForLocalNetwork: @Sendable (_ host: String) async -> LocalNetwork.Access = { _ in .allowed }
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

    static var app: Surroundings {
        Surroundings(defaults: .standard,
                     folder: Storage.directory,
                     transport: { _ in URLSessionTransport() },
                     networkSignature: LocalNetwork.signature,
                     reachesTheLAN: true,
                     asksAboutNotifications: true,
                     tvTransport: { _ in URLSessionTransport.withoutCookies() },
                     tvCredentials: KeychainTVCredentials(),
                     localNetworkAccess: { await LocalNetwork.access(probing: $0) },
                     waitForLocalNetwork: { await LocalNetwork.waitForAccess(probing: $0) {} },
                     lanInterfaces: LocalNetwork.lanInterfaces,
                     scanTransport: { URLSessionTransport.withoutCookies() },
                     scanPause: { try? await Task.sleep(for: $0) },
                     scanLog: { ScanLog.note($0) })
    }
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
