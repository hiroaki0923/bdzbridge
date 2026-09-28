import Foundation
import RecorderKit

/// What `AppModel` reaches beyond itself: where it keeps its settings and its database, how its requests get
/// to the recorder, which network it takes itself to be on, and what it does on that network and on the
/// screen of its own accord.
///
/// The app has one of these, `app`, and passes no other. It is here for the unit tests (`BDBridgeTests`),
/// which make models of their own: settings in a suite they throw away, a database in a folder of their own,
/// an invented recorder for a transport -- the demo's, or one that never answers -- and a network that
/// changes when the test says so. The model is where the bugs worth a test have been, a launch that waited on
/// itself and a line on screen that never cleared among them, and until a model could be made this way none
/// of it could be tried without a phone and a recorder.
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
    /// no packet is sent, the permission is taken as given and a recorder that is silent where it was is not
    /// looked for elsewhere. The tests run on somebody's network, where none of that may happen.
    var reachesTheLAN: Bool
    /// Whether the model asks the system about notifications. The dialog waits for a tap, and in a test
    /// there is nobody to give it.
    var asksAboutNotifications: Bool

    static var app: Surroundings {
        Surroundings(defaults: .standard,
                     folder: Storage.directory,
                     transport: { _ in URLSessionTransport() },
                     networkSignature: LocalNetwork.signature,
                     reachesTheLAN: true,
                     asksAboutNotifications: true)
    }
}
