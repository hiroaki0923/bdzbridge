import Foundation

/// The recorder's address as somebody types it, and the URLs the client builds on it.
///
/// An address is typed by hand when the scan does not find the recorder, and what a hand types is not always
/// an address: a port copied from somewhere, a space or a newline the keyboard or a paste brought along,
/// full-width digits from the Japanese keyboard, `http://` in front because that is how addresses usually
/// look. A URL built on any of those used to be forced open and crash the app, and because the address is
/// saved the moment it is set, the app crashed again at every launch after that -- before the settings,
/// where it could have been corrected, ever came up.
public enum RecorderAddress {
    /// What was typed, tidied. `port` is a port typed after the address: the recorder's ports are its own
    /// and there is nothing to choose, so it is never used, but it is kept so that the screen can say so
    /// rather than drop it without a word.
    public struct Typed: Equatable, Sendable {
        public var host: String
        public var port: String?
    }

    /// Takes off what is plainly not part of the address, and nothing else. Whatever is left may still be
    /// wrong; `isUsable` is the judge of that, and a host that is no address at all fails there, where the
    /// reader can be told, rather than being guessed at here.
    public static func tidy(_ typed: String) -> Typed {
        // NFKC turns full-width digits, dots, colons, slashes and spaces into their ASCII selves. The
        // Japanese keyboard's full stop is 。, which NFKC leaves alone, and on that keyboard it is the key
        // where the dot should be.
        var text = typed.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: "。", with: ".")
        // All of it, not only the ends: no host has a space or a line break in it, so one in the middle is
        // only ever a stray.
        text.removeAll { $0.isWhitespace }
        if let scheme = text.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(scheme)
        }
        while text.hasSuffix("/") { text.removeLast() }

        // [v6]:port, then v4-or-name:port. More than one colon without brackets is an IPv6 address, or
        // something that only looks like one, and is left for `isUsable` to decide.
        if let match = text.firstMatch(of: /^\[([^\]]*)\](?::([0-9]+))?$/) {
            return Typed(host: String(match.1), port: match.2.map(String.init))
        }
        if let match = text.firstMatch(of: /^([^:]*):([0-9]+)$/) {
            return Typed(host: String(match.1), port: String(match.2))
        }
        return Typed(host: text, port: nil)
    }

    /// Whether the client can build a URL on this host, which is the whole of the check. It is not held to
    /// being an IPv4 address: some people reach their recorder by a name their router or their VPN gives it.
    public static func isUsable(_ host: String) -> Bool {
        url(host: host, port: Upnp.port, path: "/") != nil
    }

    /// `http://host:port/path`, or nil when there is no URL to be had on `host`.
    ///
    /// What URLComponents does with a host it does not like has changed between system versions: refusing
    /// it in some, percent-encoding it in others into a URL that then fails to connect -- which would look
    /// like a recorder that is asleep, and start the waking. So the host is checked here first, and
    /// URLComponents is only ever given one that every version takes as it is.
    static func url(host: String, port: Int, path: String) -> URL? {
        guard (0...65_535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        if host.contains(":") {
            // An IPv6 address is written in brackets, which only the percent-encoded setter takes as they
            // are -- and that setter stops the app on anything it dislikes rather than refusing it, so it
            // is only given an address the system has parsed. inet_pton also takes a scope after a `%`,
            // `fe80::1%en0`, which the setter would stop on, so the characters are checked as well.
            var parsed = in6_addr()
            guard host.unicodeScalars.allSatisfy(ipv6Characters.contains),
                  inet_pton(AF_INET6, host, &parsed) == 1 else { return nil }
            components.percentEncodedHost = "[\(host)]"
        } else {
            guard !host.isEmpty, host.unicodeScalars.allSatisfy(hostCharacters.contains) else { return nil }
            components.host = host
        }
        components.port = port
        components.path = path
        return components.url
    }

    /// What a host name or an IPv4 address is made of. A name in Japanese is refused rather than turned into
    /// punycode: on a home network it is far more likely to be a word typed into the wrong field.
    private static let hostCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
    private static let ipv6Characters = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
}
