import Foundation

/// What one address of a search turned out to be.
public enum Sighting: Sendable, Equatable {
    case recorder(RecorderDescription)
    case television(TVSighting)
}

/// What a look for both kinds found, each sorted by address as `Discovery.scan`'s list is.
public struct DeviceSightings: Sendable, Equatable {
    public var recorders: [RecorderDescription]
    public var televisions: [TVSighting]

    public init(recorders: [RecorderDescription], televisions: [TVSighting]) {
        self.recorders = recorders
        self.televisions = televisions
    }

    /// Neither kind was found.
    public var isEmpty: Bool { recorders.isEmpty && televisions.isEmpty }
}

/// One search for the recorder and the television together: the press in the app asks every address of the
/// Wi-Fi whether it is either, rather than having a way in for each.
public enum DeviceSearch {
    /// Every address asked both things at once: a recorder's `description.xml` at its port (`Discovery.probe`)
    /// and a television's `getInterfaceInformation` at port 80 (`TVDiscovery.probe`), each raced against a
    /// deadline of its own. At an address where nothing lives each costs its timeout, so asked one after the
    /// other the look would take twice as long; together an address takes as long as the slower of the two,
    /// and the look about as long as a look for a recorder alone. `atOnce` addresses at a time, so twice as
    /// many requests are out.
    ///
    /// `progress` counts addresses, each done when both its requests are, out of the addresses. `found` hands
    /// over each thing as soon as its own request has answered, so that a recorder's row does not wait on its
    /// address's port 80. Both kinds go through `transport`, so that one tally (`ScanTally`) counts them all.
    public static func scan(hosts: [String], transport: any HTTPTransport, timeout: TimeInterval = 1.2,
                            atOnce: Int = 48, progress: (@Sendable (Int, Int) -> Void)? = nil,
                            found onFound: (@Sendable (Sighting) -> Void)? = nil) async -> DeviceSightings {
        let found = await Discovery.look(hosts: hosts, atOnce: atOnce, progress: progress) { host -> [Sighting] in
            async let recorder = handedOver(Discovery.probe(host, transport: transport, timeout: timeout)
                                                .map(Sighting.recorder), to: onFound)
            async let television = handedOver(TVDiscovery.probe(host, transport: transport, timeout: timeout)
                                                  .map(Sighting.television), to: onFound)
            return [await recorder, await television].compactMap { $0 }
        }
        var sightings = DeviceSightings(recorders: [], televisions: [])
        for sighting in found {
            switch sighting {
            case .recorder(let recorder): sightings.recorders.append(recorder)
            case .television(let television): sightings.televisions.append(television)
            }
        }
        sightings.recorders.sort { $0.host < $1.host }
        sightings.televisions.sort { $0.host < $1.host }
        return sightings
    }

    /// What one request of an address turned out to be, handed over as it is had.
    private static func handedOver(_ sighting: Sighting?, to found: (@Sendable (Sighting) -> Void)?) -> Sighting? {
        if let sighting { found?(sighting) }
        return sighting
    }

    /// What a press of the search came to, as the screens say it under the button.
    public enum Outcome: Sendable, Equatable {
        case found(recorders: Int, televisions: Int)
        case nothing
        case noWiFi

        /// The recorder's sentence when recorders are all that was found is the one it has always been.
        public var text: String {
            switch self {
            case .found(let recorders, 0): "レコーダーが \(recorders) 台見つかりました"
            case .found(0, let televisions): "テレビが \(televisions) 台見つかりました"
            case .found(let recorders, let televisions):
                "レコーダーが \(recorders) 台、テレビが \(televisions) 台見つかりました"
            case .nothing: "レコーダーもテレビも見つかりませんでした"
            case .noWiFi: "Wi-Fi に接続されていません。レコーダーやテレビと同じ Wi-Fi につないでから、もう一度お試しください。"
            }
        }

        /// What usually lies behind finding nothing, for the reader to go through. Two of them nobody would
        /// think of: a guest network, and a device that is not one of those the app works with.
        ///
        /// Nothing here says a recorder in standby cannot be found. It answers in network standby; what goes
        /// silent is one left off a while, which leaves the network (`docs/porting.md`). Of a television it
        /// says "may": the one television measured answered in standby, which is all that has been seen.
        public var causes: [String] {
            guard self == .nothing else { return [] }
            return [
                "iPhone が、ゲスト用の Wi-Fi など、レコーダーやテレビとは別のネットワークにつながっている。",
                "レコーダーがネットワークから外れている。電源を切ってしばらくたつと外れることがあるので、"
                    + "電源を入れてから探し直してください。",
                "テレビの電源が切れている。機種や設定によっては、電源を切ったテレビは見つからないことがあります。"
                    + "テレビの電源を入れてから探し直してください。",
                "レコーダーやテレビがネットワークにつながっていない。本体のネットワーク設定で確認できます。",
                "ソニーの BDZ シリーズ以外のレコーダーや、ソニー以外のテレビ。"
                    + "このアプリで使えるのは、ソニーの BDZ シリーズのレコーダーと、ソニーのテレビです。",
            ]
        }

        /// Whether it is said as a failure: anything but something found.
        public var failed: Bool {
            if case .found = self { return false }
            return true
        }
    }
}
