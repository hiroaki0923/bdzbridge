import Foundation

/// The demo's surroundings that are not one device's: the television's address and the pace of the recorder, the
/// invented guide written into a cache, and the devices as a search meets them. What the app keeps is its switch,
/// and the logo tiles it draws for the guide.
public extension DemoTV {
    /// The demo's television's address, beside the recorder's (`DemoRecorder.host`) and reserved for
    /// documentation as well (RFC 5737): never a real host.
    static let host = "192.0.2.64"
}

public extension DemoRecorder {
    /// How long the demo's recorder takes to answer: slow enough to look like a recorder on the far side of a
    /// room, fast enough not to wait about.
    static let answerDelay: Duration = .milliseconds(120)
}

public extension DemoLineUp {
    /// What the guide says where the invented one runs out: a broadcasting type or a day it does not cover is
    /// otherwise an empty screen pointing at a refresh that would not fill it.
    static let guideCoverage = "サンプルデータの番組表は、地デジと BS の \(guideDays) 日分です"

    /// Writes the invented guide into `store`, a cache of the demo's own: the terrestrial and satellite stations
    /// with their programmes, and a logo for each that `logo` draws -- from the two characters of the station
    /// (`Station.logo`) and its place in the line-up, for a colour -- as a PNG, or nil for none. A real recorder
    /// hands over the broadcasters' own logos, which are theirs and do not belong in a shop window, but a guide
    /// with nothing in the logo column does not look like the app either.
    @MainActor
    static func seed(_ store: GuideStore, logo: (_ text: String, _ index: Int) -> Data?) async throws {
        for (broadcasting, stations) in [("td", terrestrial), ("bs", satellite)] {
            _ = try await store.replace(services(stations), broadcasting: broadcasting)
            let logos = stations.enumerated().compactMap { index, station -> (serviceID: Int, channelNo: Int, png: Data)? in
                logo(station.logo, index).map { (station.serviceID, index + 1, $0) }
            }
            try await store.replaceLogos(logos, broadcasting: broadcasting)
        }
        // The demo's recorder answers every guide file with none, and these two are not in the line-up. Noting
        // that keeps a connect from asking it for them each time: the guide is judged fresh a broadcasting type
        // at a time, and one never answered for is always behind.
        for broadcasting in ["cs", "bs4k"] {
            try await store.noteNoGuide(broadcasting: broadcasting)
        }
        // The demo's television is in memory alone, and a launch with the demo on has none: what waited for it
        // in the demo's cache would wait for nobody.
        try await store.removePending(waitingFor: .tv)
    }
}

/// The demo's devices as its search meets them: the invented recorder at its own address and port, the invented
/// television at its own address and port 80, and silence at every other address and port, the recorder's port 80
/// and the television's recorder port included. So the search in the demo sends nothing on the LAN and never
/// raises the system's question about the local network.
public struct DemoDevices: HTTPTransport {
    public let recorder: DemoRecorder
    public let television: any HTTPTransport

    public init(recorder: DemoRecorder, television: any HTTPTransport) {
        self.recorder = recorder
        self.television = television
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let host = request.url.host() ?? ""
        if RecorderAddress.same(host, DemoRecorder.host), request.url.port == Upnp.port {
            return try await recorder.send(request)
        }
        if RecorderAddress.same(host, DemoTV.host), (request.url.port ?? 80) == 80 {
            return try await television.send(request)
        }
        throw RecorderError.transport("Nobody here.")
    }
}
