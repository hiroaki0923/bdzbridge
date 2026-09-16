import Foundation

public enum Discovery {
    /// The service that tells a Sony recorder apart from its televisions and players.
    public static let xsrsServicePrefix = "urn:schemas-xsrs-org:service:X_ScheduledRecording"

    /// Looks through the addresses for a recorder, by asking each one for its `description.xml`. A host that
    /// is not there, or is something else, drops out on the timeout or on the parse; what comes back is only
    /// recorders. `progress` is called with how many addresses have been tried.
    ///
    /// There is no separate port scan: the description is what confirms a recorder anyway, so one short
    /// request per address does both jobs. A recorder that is there answers in milliseconds; the timeout is
    /// only ever paid on the addresses where nothing lives, which is why the two numbers below matter more
    /// than they look: 253 addresses take about six seconds on a home network.
    public static func scan(hosts: [String], transport: any HTTPTransport = URLSessionTransport(),
                            port: Int = Upnp.port, timeout: TimeInterval = 1.2, atOnce: Int = 48,
                            progress: (@Sendable (Int, Int) -> Void)? = nil,
                            found onFound: (@Sendable (RecorderDescription) -> Void)? = nil) async -> [RecorderDescription] {
        guard !hosts.isEmpty else { return [] }
        var found: [RecorderDescription] = []
        var done = 0

        await withTaskGroup(of: RecorderDescription?.self) { group in
            var next = 0
            func add() {
                guard next < hosts.count else { return }
                let host = hosts[next]
                next += 1
                group.addTask {
                    await probe(host, transport: transport, port: port, timeout: timeout)
                }
            }
            for _ in 0..<min(atOnce, hosts.count) { add() }
            for await candidate in group {
                done += 1
                progress?(done, hosts.count)
                if let candidate {
                    found.append(candidate)
                    onFound?(candidate)
                }
                add()
            }
        }
        return found.sorted { $0.host < $1.host }
    }

    /// One address: a recorder, or nothing.
    ///
    /// The request's own timeout is not the only clock. On an iPhone a scan was seen stop at its last
    /// address and stay there, which means one request outlived the timeout it was given; whatever the
    /// session was waiting for, a scan must end, so the probe is also raced against a deadline of its own
    /// and gives up when that passes.
    public static func probe(_ host: String, transport: any HTTPTransport = URLSessionTransport(),
                             port: Int = Upnp.port, timeout: TimeInterval = 1.5) async -> RecorderDescription? {
        let location = "http://\(host):\(port)/description.xml"
        guard let url = URL(string: location) else { return nil }
        return await withTaskGroup(of: RecorderDescription?.self) { group in
            group.addTask {
                guard let response = try? await transport.send(HTTPRequest(url: url, timeout: timeout)),
                      response.statusCode == 200 else { return nil }
                return parseDescription(response.text, host: host, port: port, location: location, via: "scan")
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout + 1))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Reads a candidate's `description.xml`. Returns nil for anything that is not a Sony recorder with the
    /// reservation service, which is how televisions and other DLNA servers on the LAN are filtered out.
    public static func parseDescription(_ xml: String, host: String, port: Int = Upnp.port,
                                        location: String, via: String) -> RecorderDescription? {
        guard let root = try? XmlNode.parse(xml) else { return nil }

        func text(_ name: String) -> String {
            (root.firstDescendantText(name) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let services = root.descendants("serviceType").map { $0.text }
        guard text("manufacturer") == "Sony Corporation",
              services.contains(where: { $0.hasPrefix(xsrsServicePrefix) }) else { return nil }

        let product = text("productName").isEmpty ? text("modelName") : text("productName")
        return RecorderDescription(
            host: host,
            port: port,
            friendlyName: text("friendlyName"),
            product: product,
            model: text("modelDescription"),
            udn: text("UDN"),
            epgCapable: !["", "00"].contains(text("EPG_CAP")),
            location: location,
            via: via
        )
    }
}
