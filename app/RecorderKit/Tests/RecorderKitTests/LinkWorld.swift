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
    /// How long a read of the USB slot left for later waits: a moment, unless a test that ends one before it is
    /// made gives the app's minute. Read as the link is made.
    var slotReadAgainAfter: Duration = .milliseconds(1)
    /// How long the slot is waited for before something that names it is sent: the app's two seconds for ten, as
    /// milliseconds. Read as the link is made.
    var slotSettling = SlotSettling(every: .milliseconds(2), for: .milliseconds(10))

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
            },
            slotReadAgainAfter: slotReadAgainAfter,
            slotSettling: slotSettling)
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
    /// What the host does when it is told to send what waits, as an app's asks its driver: for a test of a
    /// sending, which keeps what the driver hands back.
    var onSendWhatWaits: (@MainActor () async -> Void)?
    /// Every line that was put up, in the order it was asked for: `line` says only what is up now. Beside
    /// `events` and not among them, which tests compare whole.
    private(set) var begun: [String] = []

    func beginActivity(_ text: String) -> Activities.Token {
        begun.append(text)
        return lines.begin(text)
    }
    func updateActivity(_ token: Activities.Token, to text: String) { lines.update(token, to: text) }
    func endActivity(_ token: Activities.Token) { lines.end(token) }
    var isBusy: Bool { false }
    var holdsOffConnect: Bool { false }
    var isDemo: Bool { false }
    /// The phone's cache, for a test of what is sent from it: none unless a test gives one.
    var cache: GuideStore?
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
    func sendWhatWaits() async {
        events.append("send what waits")
        await onSendWhatWaits?()
    }
    func reached() async {
        events.append("reached")
        await onReached?()
    }
    func anotherAnsweredTheCheck() { events.append("another device on the check") }
    func sayNotConnected() { problem = Self.notConnected }
    func waitForPermission(at host: String) { waitingAt = host }
    func stopWaitingForPermission() { waitingAt = nil }
}
