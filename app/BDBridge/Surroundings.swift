import Foundation
import RecorderKit

/// What `AppModel` reaches beyond itself: where it keeps its settings and its database, how its requests get
/// to the recorder, which network it takes itself to be on, and what it does on that network and on the
/// screen of its own accord.
///
/// The app has one of these, `app`, and passes no other. It is here for the unit tests (`BDBridgeTests`),
/// which make models of their own: settings in a suite they throw away, a database in a folder of their own,
/// an invented recorder for a transport -- the demo's, or one that never answers -- and a network that
/// changes when the test says so.
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

    static var app: Surroundings {
        Surroundings(defaults: .standard,
                     folder: Storage.directory,
                     transport: { _ in URLSessionTransport() },
                     networkSignature: LocalNetwork.signature,
                     reachesTheLAN: true,
                     asksAboutNotifications: true)
    }
}
