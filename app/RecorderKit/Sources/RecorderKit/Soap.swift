import Foundation

/// The recorder is unauthenticated on the LAN but very particular about the shape of a request: it answers
/// UPnP error 402 to any deviation. These builders must keep producing byte-identical payloads, which is what
/// docs/port/xsrs.json pins down.
public enum Soap {
    /// Escapes for XML text. `quotes` matches Python's `html.escape` default, which the SOAP arguments use;
    /// element bodies built by hand use `quotes: false`.
    public static func escape(_ text: String, quotes: Bool = true) -> String {
        var out = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if quotes {
            out = out
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#x27;")
        }
        return out
    }

    /// The SOAP envelope, with no whitespace between elements.
    public static func body(service: String, action: String, arguments: [(String, String)] = []) -> String {
        let inner = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\" "
            + "xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>"
            + "<u:\(action) xmlns:u=\"\(service)\">\(inner)</u:\(action)></s:Body></s:Envelope>"
    }

    /// Headers the official app sends. `Accept-Language` matters for the text the recorder returns.
    public static func headers(service: String, action: String) -> [String: String] {
        [
            "Content-Type": "text/xml; charset=\"utf-8\"",
            "Accept-Language": "ja",
            "SOAPACTION": "\"\(service)#\(action)\"",
        ]
    }

    /// The `errorCode` of a SOAP fault, if the response carries one. 402 means the request shape was rejected,
    /// 820 an unknown title id, 880 a recorder that is in network standby.
    public static func errorCode(in response: XmlNode) -> String? {
        response.firstDescendantText("errorCode")
    }
}

/// Lowercase hex with an `0x` prefix and no padding, as the recorder writes ids.
func hex(_ value: Int) -> String {
    "0x" + String(value, radix: 16)
}

/// Lowercase hex padded to four digits, the form `scheduledChannelID` uses.
func hex4(_ value: Int) -> String {
    let digits = String(value, radix: 16)
    return "0x" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
}

/// Parses `0x0418` and `418` alike.
func hexInt(_ text: String) -> Int? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("0x") { trimmed = String(trimmed.dropFirst(2)) }
    return Int(trimmed, radix: 16)
}
