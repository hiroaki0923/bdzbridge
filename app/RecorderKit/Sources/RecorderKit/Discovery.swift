import Foundation

public enum Discovery {
    /// The service that tells a Sony recorder apart from its televisions and players.
    public static let xsrsServicePrefix = "urn:schemas-xsrs-org:service:X_ScheduledRecording"

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
