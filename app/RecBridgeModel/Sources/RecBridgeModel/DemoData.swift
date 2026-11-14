import Foundation
import RecorderKit

/// The demo: its switch, and the seed of its guide.
///
/// Two jobs. It is how the App Store screenshots are taken: on a real recorder the screens say what somebody
/// watches, where they live and what they pay for, which does not belong in a shop window. And it is what
/// the tutorial offers to anyone without a recorder to hand, the App Store's reviewer among them.
///
/// What it shows is invented in RecorderKit: the recorder (`DemoRecorder`), which answers in the XML a
/// BDZ-FBT4100 really sends and remembers what is done to it, the stations and their programmes it is made from
/// (`DemoLineUp`), and the television (`DemoTV`), with their addresses, their pace, the guide written out of the
/// line-up and the devices as the demo's search meets them (`DemoDevices`). Here is the switch. The logo tiles
/// drawn for the guide are the app's (`DemoTiles.swift`), and the guide goes into a database of its own, so that
/// trying the demo leaves nothing in the cache of a real recorder.
///
/// It has a television too, which the reader adds from the demo's search (`DemoLineUp.television()`): the
/// package's invented one, receiving the guide's stations and listing what it records under the guide's titles.
/// It is kept in memory alone, with its registration, and goes with the demo.
public enum DemoData {
    public static var on: Bool { on(in: .standard) }

    /// The same, in the defaults a model was given (`Surroundings.defaults`).
    static func on(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: DefaultsKey.demoData) }

    /// Whether to say on screen that the data is invented. On, always, for anyone using the demo -- the free
    /// space and the recordings on those screens are not theirs. Off for the App Store screenshots
    /// (`-demoBanner 0`), which are pictures of the app as it looks with a real recorder. Read in the defaults a
    /// model was given (`Surroundings.defaults`), which in the app are the ones a launch argument reaches.
    static func banner(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: DefaultsKey.demoBanner) == nil || defaults.bool(forKey: DefaultsKey.demoBanner)
    }

    /// Remembers the real recorder, if there is one, and turns the demo on.
    static func turnOn(realHost: String, realMac: String?, in defaults: UserDefaults) {
        defaults.set(realHost, forKey: DefaultsKey.hostBeforeDemo)
        defaults.set(realMac ?? "", forKey: DefaultsKey.macBeforeDemo)
        defaults.set(true, forKey: DefaultsKey.demoData)
    }

    /// Turns the demo off and hands back the recorder that was there before it, if any.
    static func turnOff(in defaults: UserDefaults) -> (host: String, mac: String?) {
        let host = defaults.string(forKey: DefaultsKey.hostBeforeDemo) ?? ""
        let mac = defaults.string(forKey: DefaultsKey.macBeforeDemo) ?? ""
        defaults.removeObject(forKey: DefaultsKey.hostBeforeDemo)
        defaults.removeObject(forKey: DefaultsKey.macBeforeDemo)
        defaults.set(false, forKey: DefaultsKey.demoData)
        return (host, mac.isEmpty ? nil : mac)
    }
}
