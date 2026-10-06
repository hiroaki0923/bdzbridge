import Foundation
import RecorderKit

/// What `AppModel` reaches beyond itself: where it keeps its settings and its database, how its requests get
/// to the recorder, which network it takes itself to be on, what it does on that network and on the
/// screen of its own accord, and what a search for a recorder looks round, waits on and asks through.
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
    /// How requests reach the television at an address: a transport that keeps no cookies of its own, since
    /// the client sends its registration's by hand. Nothing answers unless a test says otherwise.
    var tvTransport: (_ host: String) -> any HTTPTransport = { _ in NoTelevision() }
    /// Where the television's registration is kept: the Keychain in the app, memory in a test.
    var tvCredentials: any TVCredentialStore = MemoryTVCredentials()
    /// The interfaces a search for a recorder looks round (`AppModel.scanForRecorders`): the Wi-Fi's in the
    /// app. None unless a test puts its phone on one, and a search then says there is no Wi-Fi and asks nobody.
    var lanInterfaces: () -> [LocalNetwork.Interface] = { [] }
    /// How a search waits for the reader to allow the local network before it asks anybody
    /// (`LocalNetwork.waitForAccess`): aimed at a neighbour on the subnet, saying so each time the permission
    /// is in the way, and back with whether it was given. Given at once unless a test says otherwise.
    var waitForLocalNetwork: @Sendable (_ neighbour: String, _ blocked: @Sendable () async -> Void) async -> Bool
        = { _, _ in true }
    /// What one search sends its requests through, to every address of the subnet: made anew for each search,
    /// as the app's session is. Nobody answers unless a test says otherwise.
    var scanTransport: () -> any HTTPTransport = { NoRecorderAnywhere() }
    /// How long a search that found nobody holds that back before saying it, which is the time a question of
    /// the system's raised by the press has to take the app out of being active; and how long after the app is
    /// active again the search is made once more (`AppModel.scanForRecorders`). A test has no seconds to spend
    /// on either.
    var emptyScanHold: Duration = .seconds(1)
    var scanAgainDelay: Duration = .seconds(1)
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
                     lanInterfaces: LocalNetwork.lanInterfaces,
                     waitForLocalNetwork: { await LocalNetwork.waitForAccess(probing: $0, blocked: $1) == .allowed },
                     scanTransport: { URLSessionTransport() },
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
