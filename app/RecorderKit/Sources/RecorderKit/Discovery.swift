import Foundation

public enum Discovery {
    /// The service that tells a Sony recorder apart from its televisions and players.
    public static let xsrsServicePrefix = "urn:schemas-xsrs-org:service:X_ScheduledRecording"

    /// Looks through the addresses for a recorder, by asking each one for its `description.xml`. A host that is
    /// not there, or is something else, drops out on the timeout or on the parse; what comes back is only
    /// recorders. `progress` is called with how many addresses have been tried, and `until` ends the scan at
    /// the first recorder it accepts: the probes still out are cancelled and no more addresses are asked.
    ///
    /// There is no separate port scan: the description is what confirms a recorder anyway. A recorder that is
    /// there answers in milliseconds, so the timeout is only paid where nothing lives, which is why `timeout`
    /// and `atOnce` matter more than they look: 253 addresses take about six seconds on a home network.
    public static func scan(hosts: [String], transport: any HTTPTransport = URLSessionTransport(),
                            port: Int = Upnp.port, timeout: TimeInterval = 1.2, atOnce: Int = 48,
                            progress: (@Sendable (Int, Int) -> Void)? = nil,
                            found onFound: (@Sendable (RecorderDescription) -> Void)? = nil,
                            until: (@Sendable (RecorderDescription) -> Bool)? = nil) async -> [RecorderDescription] {
        guard !hosts.isEmpty else { return [] }
        var found: [RecorderDescription] = []
        var done = 0

        await withTaskGroup(of: RecorderDescription?.self) { group in
            var next = 0
            var stopped = false
            func add() {
                guard !stopped, next < hosts.count else { return }
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
                    if until?(candidate) == true {
                        stopped = true
                        group.cancelAll()
                    }
                }
                add()
            }
        }
        return found.sorted { $0.host < $1.host }
    }

    /// Looks through the addresses for one recorder, the one whose UDN ends with `mac` (see
    /// `RecorderDescription.hasMAC`), and stops as soon as it has answered. For a recorder that is no longer
    /// where it was: its address is a DHCP lease, and the router hands it out again as it likes.
    public static func find(mac: String, among hosts: [String], transport: any HTTPTransport = URLSessionTransport(),
                            port: Int = Upnp.port, timeout: TimeInterval = 1.2,
                            atOnce: Int = 48) async -> RecorderDescription? {
        let found = await scan(hosts: hosts, transport: transport, port: port, timeout: timeout, atOnce: atOnce,
                               until: { $0.hasMAC(mac) })
        return found.first { $0.hasMAC(mac) }
    }

    /// One address: a recorder, or nothing. The request's own timeout is not the only clock: on an iPhone a
    /// scan was seen to stop at its last address and stay there, one request having outlived the timeout it was
    /// given. A scan must end, so the probe is also raced against a deadline of its own.
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

    /// One request of a search's kind to one address, read for how it came back and not for who lives there:
    /// whether it was turned away before it could have been out for its time (`ScanTally.Counts`'s
    /// `turnedAwayWhole`, of the one request).
    ///
    /// For a search whose look through the subnet was turned away whole, which is what the system's question
    /// about the local network may do to it: "it may deny the operation immediately, before the user has
    /// responded to the alert", and for requests that cannot be made through an API that waits for
    /// connectivity, "add appropriate retry logic" (Apple's TN3179). A search's requests cannot: a session
    /// that waits also waits, without end, on an address that refuses (`docs/porting.md`). So the search asks
    /// one address until a request is let out, and looks again then. The asking, and how often, is the
    /// caller's; this is the one request and the reading of it.
    public static func turnedAway(at host: String, transport: any HTTPTransport = URLSessionTransport(),
                                  port: Int = Upnp.port, timeout: TimeInterval = 1.2) async -> Bool {
        let tally = ScanTally(transport)
        _ = await probe(host, transport: tally, port: port, timeout: timeout)
        return await tally.counts.turnedAwayWhole
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
