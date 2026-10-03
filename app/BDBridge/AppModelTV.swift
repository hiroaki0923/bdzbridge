import Foundation
import RecorderKit

/// The television: its link, made when one is saved, and the steps that add it -- finding it at an address,
/// registering with it by the PIN it shows -- and take it away.
///
/// It has a link of its own beside the recorder's (`DeviceLink` with a `TVDriver`), told the same things --
/// the app coming back, the network changing -- and answering to a host of its own (`TVHost`), so that neither
/// device's silence, problem or wait for the local network permission is the other's. What the television said
/// is kept by that host too -- its reservations -- and goes when the link is let go of. Not in the demo, whose
/// recorder is invented: a real television would otherwise answer beside it.
extension AppModel {
    var tvDriver: TVDriver? { tv?.driver as? TVDriver }

    /// What the television is listed as among the devices registered with it.
    static let tvNickname = "BD Bridge"

    /// The line that says what went wrong with a device, for whatever shows a reservation's failure: the
    /// recorder's is the model's own, the television's its host's. Each device's operations write to its own.
    func problem(for device: DeviceSlot) -> String? {
        device == .tv ? tvHost?.problem : problem
    }

    /// Whether a device is busy, for the buttons that write to the device a reservation is held by: the
    /// recorder's work is the model's own (`isBusy`), the television's its host's, and neither holds back a
    /// button of the other's. A television the app has let go of counts as busy: a row of its still on a
    /// screen has nothing to be sent to.
    func isBusy(for device: DeviceSlot) -> Bool {
        device == .tv ? tvHost?.isBusy ?? true : isBusy
    }

    /// Makes the television's link from what is saved, when a television is saved and the demo is off: known by
    /// the MAC saved with it from the first answer, and renewing its registration only with the app in front.
    /// Connects nothing.
    func makeTVLink() {
        guard tv == nil, !demo, let host = defaults.string(forKey: DefaultsKey.tvHost), !host.isEmpty else { return }
        let owner = TVHost(model: self)
        let driver = TVDriver(credentials: surroundings.tvCredentials, nickname: Self.tvNickname,
                              inFront: { [weak self] in self.map { !$0.inBackground } ?? false })
        let link = DeviceLink(host: host, session: SessionState(device: defaults.string(forKey: DefaultsKey.tvMac)),
                              driver: driver, environment: tvLinkEnvironment())
        link.owner = owner
        owner.link = link
        tvHost = owner
        tv = link
    }

    /// Lets go of the television's link, and of a wait for the permission it had set going. What the television
    /// said goes with its host -- its reservations, and its line of what went wrong -- so no list is emptied
    /// here; the screens are told that it went (`tvTimesForgotten`), when there was a link to let go of. The
    /// lines its host had up are on the model's own list, and come down now rather than when the requests
    /// they stand for end: what is still out on a television the app has let go of says nothing on the screens.
    func dropTVLink() {
        if tv != nil { tvTimesForgotten += 1 }
        tvHost?.stopWaitingForPermission()
        tvHost?.takeDownLines()
        tv = nil
        tvHost = nil
    }

    /// The LAN as the television's link sees it: requests by the television's transport, and nothing else. It is
    /// never woken or looked for elsewhere, and the permission is asked about as the recorder's link asks.
    func tvLinkEnvironment() -> LinkEnvironment {
        LinkEnvironment(
            transport: { [weak self] host in self?.surroundings.tvTransport(host) ?? NoTelevision() },
            networkSignature: { [weak self] in self?.surroundings.networkSignature() ?? "" },
            sendPacket: { _, _ in },
            lanIsBlocked: { [weak self] host in
                guard let self, !self.demo, self.surroundings.reachesTheLAN else { return false }
                return await LocalNetwork.access(probing: host) == .blocked
            },
            hostsNear: { _ in [] },
            findRecorder: { _, _ in nil })
    }

    // MARK: - adding one

    /// What was found at an address the reader gave for the television: the package's answer, under the name
    /// the screens know it by.
    typealias TVFound = TVPresence

    /// Asks the device at `host` what it is, without a registration and without changing anything
    /// (`ScalarClient.presence`).
    func findTV(at host: String) async -> TVFound {
        let client = ScalarClient(host: host, transport: surroundings.tvTransport(host),
                                  credentials: surroundings.tvCredentials)
        return await client.presence()
    }

    /// What became of a registration.
    enum TVRegistered: Equatable {
        /// The television wants its PIN, which it shows on its screen when it is showing a broadcast.
        case pinNeeded
        case registered
        case failed(String)
    }

    /// Registers with the television at `host`: with nothing at first, when it answers by putting its PIN on its
    /// screen, and then with the PIN the reader read there. The steps, and what each failure is said as, are
    /// the client's (`ScalarClient.enrol`). What is the app's is the client id, made once and kept, so that the
    /// PIN goes with the request that asked for it; and, once registered, saving the television and connecting
    /// to it on a link made afresh: an attach still out on the last one, with the last cookie, ends there.
    func registerTV(at host: String, pin: String?) async -> TVRegistered {
        let credentials = surroundings.tvCredentials
        let clientID = credentials.load()?.clientID ?? tvClientID ?? "BDBridge:\(UUID().uuidString)"
        tvClientID = clientID
        let client = ScalarClient(host: host, transport: surroundings.tvTransport(host), credentials: credentials)
        switch await client.enrol(clientID: clientID, nickname: Self.tvNickname, pin: pin) {
        case .pinNeeded:
            return .pinNeeded
        case .failed(let why):
            return .failed(why)
        case .registered(let mac):
            tvClientID = nil
            dropTVLink()
            defaults.set(host, forKey: DefaultsKey.tvHost)
            if let mac {
                defaults.set(mac, forKey: DefaultsKey.tvMac)
            } else {
                defaults.removeObject(forKey: DefaultsKey.tvMac)
            }
            makeTVLink()
            await tv?.connect()
            return .registered
        }
    }

    /// Takes the television away: its link, its address and its registration. What the television itself
    /// lists as registered is left; it can be removed from the list in the television's settings.
    func removeTV() {
        dropTVLink()
        surroundings.tvCredentials.remove()
        defaults.removeObject(forKey: DefaultsKey.tvHost)
        defaults.removeObject(forKey: DefaultsKey.tvMac)
        tvClientID = nil
    }
}
