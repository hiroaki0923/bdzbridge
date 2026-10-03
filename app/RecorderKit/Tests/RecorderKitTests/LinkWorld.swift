import Foundation
@testable import RecorderKit

/// Everything beyond a link, for the tests of links: the app it tells (`LinkHost`) and the network it reaches
/// (`LinkEnvironment`). What the link did to either is put down in `events`, in the order it did it, and the world
/// answers as the test says: the device at each address in `devices`, silence anywhere else.
@MainActor
final class LinkWorld: LinkHost {
    var events: [String] = []
    /// What answers at each address.
    var devices: [String: any HTTPTransport] = [:]
    /// Whether local network privacy is what stops the asks.
    var blocked = false
    /// The addresses the app gives to look through for a recorder that has moved.
    var near: [String] = []
    /// What a search of them finds.
    var found: RecorderDescription?

    var problem: String?
    var macReadAt: String?
    private(set) var waitingAt: String?
    private var lines = Activities()
    private let nobody = StubTransport { _, _ in throw RecorderError.transport("Nothing is here.") }

    var environment: LinkEnvironment {
        LinkEnvironment(
            transport: { host in self.devices[host] ?? self.nobody },
            networkSignature: { "home" },
            sendPacket: { mac, host in self.events.append("packet \(mac) for \(host)") },
            lanIsBlocked: { host in
                self.events.append("permission at \(host)")
                return self.blocked
            },
            hostsNear: { _ in self.near },
            findRecorder: { mac, _ in
                self.events.append("search for \(mac)")
                return self.found
            })
    }

    func put(_ event: String) { events.append(event) }

    /// The packets and the asks of who is there, without the rest.
    var onTheNetwork: [String] {
        events.filter { $0.hasPrefix("packet") || $0.hasPrefix("ask description.xml") }
    }

    func count(_ prefix: String) -> Int { events.filter { $0.hasPrefix(prefix) }.count }

    /// The line on screen for what is under way, or nil when nothing is.
    var line: String? { lines.current }
    /// What `sayNotConnected` says, as each of the app's hosts has a sentence of its own for it.
    static let notConnected = "not connected"

    /// What the host does once a connect has reached the device, inside that connect: a read, for a test of one
    /// asked for from there.
    var onReached: (@MainActor () async -> Void)?

    func beginActivity(_ text: String) -> Activities.Token { lines.begin(text) }
    func updateActivity(_ token: Activities.Token, to text: String) { lines.update(token, to: text) }
    func endActivity(_ token: Activities.Token) { lines.end(token) }
    var isBusy: Bool { false }
    var holdsOffConnect: Bool { false }
    var isDemo: Bool { false }
    var cache: GuideStore? { nil }
    func cacheForAttempt() async {}
    func keepAddress(_ host: String) { events.append("address \(host)") }
    func keepMAC(_ text: String) { events.append("MAC \(text)") }
    func macWasReadAt(_ host: String) {
        macReadAt = host
        events.append("MAC read at \(host)")
    }
    func forgetMac() { events.append("MAC forgotten") }
    func anotherDeviceDescribedItself(wasConnected: Bool) { events.append("another device") }
    func cacheMadeOver() async {}
    func cacheCouldNotBeMadeOver() {}
    func sendWhatWaits() async { events.append("send what waits") }
    func reached() async {
        events.append("reached")
        await onReached?()
    }
    func anotherAnsweredTheCheck() { events.append("another device on the check") }
    func sayNotConnected() { problem = Self.notConnected }
    func waitForPermission(at host: String) { waitingAt = host }
    func stopWaitingForPermission() { waitingAt = nil }
}
