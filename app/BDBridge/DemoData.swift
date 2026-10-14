import Foundation
import RecorderKit
import UIKit

/// The demo: its switch, and the seed of its guide.
///
/// Two jobs. It is how the App Store screenshots are taken: on a real recorder the screens say what somebody
/// watches, where they live and what they pay for, which does not belong in a shop window. And it is what
/// the tutorial offers to anyone without a recorder to hand, the App Store's reviewer among them.
///
/// What it shows is invented in RecorderKit: the recorder (`DemoRecorder`), which answers in the XML a
/// BDZ-FBT4100 really sends and remembers what is done to it, the stations and their programmes it is made from
/// (`DemoLineUp`), and the television (`DemoTV`). Here are the switch, the address and the pace the app gives
/// them, and the guide, which `seed` writes out of the line-up, with logo tiles drawn here, into a database of
/// its own, so that trying the demo leaves nothing in the cache of a real recorder.
///
/// It has a television too, which the reader adds from the demo's search (`DemoLineUp.television()`): the
/// package's invented one, receiving the guide's stations and listing what it records under the guide's titles.
/// It is kept in memory alone, with its registration, and goes with the demo.
enum DemoData {
    static var on: Bool { on(in: .standard) }

    /// The same, in the defaults a model was given (`Surroundings.defaults`).
    static func on(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: DefaultsKey.demoData) }

    /// Whether to say on screen that the data is invented. On, always, for anyone using the demo -- the free
    /// space and the recordings on those screens are not theirs. Off for the App Store screenshots
    /// (`-demoBanner 0`), which are pictures of the app as it looks with a real recorder.
    static var banner: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.demoBanner) == nil
            || UserDefaults.standard.bool(forKey: DefaultsKey.demoBanner)
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

    /// The demo's television's address, beside the recorder's and reserved for documentation as well. Its MAC,
    /// its model and its number are the package's invented ones (`DemoTV`).
    static let tvHost = "192.0.2.64"
    /// How long the demo's recorder takes to answer: slow enough to look like a recorder on the far side of a
    /// room, fast enough not to wait about.
    static let answerDelay: Duration = .milliseconds(120)

    // MARK: - filling the guide cache

    /// What `seed` writes, in words, for the guide to say where the invented one runs out: a broadcasting type
    /// or a day it does not cover is otherwise an empty screen pointing at a refresh that would not fill it.
    static let guideCoverage = "サンプルデータの番組表は、地デジと BS の \(DemoLineUp.guideDays) 日分です"

    /// Writes the invented guide into the app's own cache, which is where the screens read it from.
    static func seed(store: GuideStore) async throws {
        for (broadcasting, stations) in [("td", DemoLineUp.terrestrial), ("bs", DemoLineUp.satellite)] {
            _ = try await store.replace(DemoLineUp.services(stations), broadcasting: broadcasting)
            try await store.replaceLogos(await logos(for: stations), broadcasting: broadcasting)
        }
        // The demo's recorder answers every guide file with none, and these two are not invented here. Noting
        // that keeps a connect from asking it for them each time: the guide is judged fresh a broadcasting type
        // at a time, and one never answered for is always behind.
        for broadcasting in ["cs", "bs4k"] {
            try await store.noteNoGuide(broadcasting: broadcasting)
        }
        // The demo's television is in memory alone, and a launch with the demo on has none: what waited for it
        // in the demo's cache would wait for nobody.
        try await store.removePending(waitingFor: .tv)
    }

    /// Invented station logos: a coloured tile with two characters on it (`Station.logo`). A real recorder
    /// hands over the broadcasters' own logos, which are theirs and do not belong in a shop window, but a
    /// guide with nothing in the logo column does not look like the app either.
    @MainActor
    private static func logos(for stations: [DemoLineUp.Station]) -> [(serviceID: Int, channelNo: Int, png: Data)] {
        stations.enumerated().compactMap { index, station in
            guard let png = tile(station.logo, colour: tileColours[index % tileColours.count]) else {
                return nil
            }
            return (station.serviceID, index + 1, png)
        }
    }

    private static let tileColours: [UIColor] = [
        UIColor(red: 0.20, green: 0.44, blue: 0.80, alpha: 1),
        UIColor(red: 0.16, green: 0.58, blue: 0.42, alpha: 1),
        UIColor(red: 0.84, green: 0.36, blue: 0.24, alpha: 1),
        UIColor(red: 0.45, green: 0.32, blue: 0.70, alpha: 1),
        UIColor(red: 0.84, green: 0.60, blue: 0.16, alpha: 1),
        UIColor(red: 0.24, green: 0.55, blue: 0.62, alpha: 1),
    ]

    @MainActor
    private static func tile(_ text: String, colour: UIColor) -> Data? {
        let size = CGSize(width: 64, height: 36)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            colour.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let bounds = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: (size.width - bounds.width) / 2,
                                                y: (size.height - bounds.height) / 2),
                                    withAttributes: attributes)
            _ = context
        }
    }
}


/// The demo's devices as its search meets them (`AppModel.scanForDevices`): the invented recorder at its own
/// address and port, the invented television at its own address and port 80, and silence at every other
/// address and port, the recorder's port 80 and the television's recorder port included. So the search in the
/// demo sends nothing on the LAN and never raises the system's question about the local network.
struct DemoDevices: HTTPTransport {
    let recorder: DemoRecorder
    let television: any HTTPTransport

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let host = request.url.host() ?? ""
        if RecorderAddress.same(host, DemoRecorder.host), request.url.port == Upnp.port {
            return try await recorder.send(request)
        }
        if RecorderAddress.same(host, DemoData.tvHost), (request.url.port ?? 80) == 80 {
            return try await television.send(request)
        }
        throw RecorderError.transport("Nobody here.")
    }
}
