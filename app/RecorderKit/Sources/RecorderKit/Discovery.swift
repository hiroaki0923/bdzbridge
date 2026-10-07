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
        let found = await look(hosts: hosts, atOnce: atOnce, progress: progress, found: onFound, until: until) { host in
            await probe(host, transport: transport, port: port, timeout: timeout).map { [$0] } ?? []
        }
        return found.sorted { $0.host < $1.host }
    }

    /// The loop of every look through the addresses, whatever it asks each one: `probe` is the asking, and hands
    /// back what the address turned out to be, nothing for most. `atOnce` addresses are asked at a time, the next
    /// begun as one is done. `progress` counts the addresses done, `found` hears of each thing as its address
    /// answers, and `until` ends the look at the first thing it accepts: the probes still out are cancelled and no
    /// more addresses are asked. What was found comes back in the order it answered.
    static func look<Found: Sendable>(hosts: [String], atOnce: Int,
                                      progress: (@Sendable (Int, Int) -> Void)? = nil,
                                      found onFound: (@Sendable (Found) -> Void)? = nil,
                                      until: (@Sendable (Found) -> Bool)? = nil,
                                      probe: @escaping @Sendable (String) async -> [Found]) async -> [Found] {
        guard !hosts.isEmpty else { return [] }
        var found: [Found] = []
        var done = 0

        await withTaskGroup(of: [Found].self) { group in
            var next = 0
            var stopped = false
            func add() {
                guard !stopped, next < hosts.count else { return }
                let host = hosts[next]
                next += 1
                group.addTask { await probe(host) }
            }
            for _ in 0..<min(atOnce, hosts.count) { add() }
            for await answers in group {
                done += 1
                progress?(done, hosts.count)
                for answer in answers {
                    found.append(answer)
                    onFound?(answer)
                    if until?(answer) == true {
                        stopped = true
                        group.cancelAll()
                    }
                }
                add()
            }
        }
        return found
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

    /// One address: a recorder, or nothing. Raced against a deadline of its own (`raced`).
    public static func probe(_ host: String, transport: any HTTPTransport = URLSessionTransport(),
                             port: Int = Upnp.port, timeout: TimeInterval = 1.5) async -> RecorderDescription? {
        let location = "http://\(host):\(port)/description.xml"
        guard let url = URL(string: location) else { return nil }
        return await raced(timeout) {
            guard let response = try? await transport.send(HTTPRequest(url: url, timeout: timeout)),
                  response.statusCode == 200 else { return nil }
            return parseDescription(response.text, host: host, port: port, location: location, via: "scan")
        }
    }

    /// What `ask` hands back, or nothing once `timeout` and a second more have gone by, for the probe of one
    /// address of a look. The request's own timeout is not the only clock: on an iPhone a scan was seen to stop
    /// at its last address and stay there, one request having outlived the timeout it was given. A look must
    /// end, so every probe of one is also raced against a deadline of its own.
    static func raced<Value: Sendable>(_ timeout: TimeInterval,
                                       _ ask: @escaping @Sendable () async -> Value?) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await ask() }
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
    /// whether the system turned it away, by the rule a search reads its look by (`ScanTally.Counts`'s
    /// `mostTurnedAway`, of the one request).
    ///
    /// For a search whose look through the subnet was turned away, which is what the system's question about
    /// the local network may do to it: "it may deny the operation immediately, before the user has responded
    /// to the alert", and for requests that cannot be made through an API that waits for connectivity, "add
    /// appropriate retry logic" (Apple's TN3179). A search's requests cannot: a session that waits was seen,
    /// on a Mac, to wait on an address that refused as well, and not to end (`docs/porting.md`). So the search
    /// asks again, at an address its look saw turned away (`ScanTally.turnedAwayAt`), until a request is let
    /// out, and looks again then. The system turned that address's request of this kind away, so it is not one
    /// the system lets through unasked, and its refusing the request is the request let out as much as its
    /// answering, or its silence until the request times out. Of this kind: a search that also asks another
    /// kind keeps the address from this kind's requests alone (`ScanTally(_:keepingAddressFrom:)`), since the
    /// address let through unasked may fail at another port with a code read as turned away. That the request
    /// is turned away while the permission is in the way and let out once it is given is the technote's of
    /// every operation, "If your program has local network access, the system allows the operation. If not,
    /// the system blocks it.", and not yet seen on a phone for a request asked again. The asking, and how
    /// often, is the caller's; this is the one request and the reading of it.
    public static func turnedAway(at host: String, transport: any HTTPTransport = URLSessionTransport(),
                                  port: Int = Upnp.port, timeout: TimeInterval = 1.2) async -> Bool {
        let tally = ScanTally(transport)
        _ = await probe(host, transport: tally, port: port, timeout: timeout)
        return await tally.counts.mostTurnedAway
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
