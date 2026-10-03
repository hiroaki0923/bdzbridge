import Foundation
import RecorderKit

/// The television: its link, made when one is saved, and the steps that add it -- finding it at an address,
/// registering with it by the PIN it shows -- and take it away.
///
/// It has a link of its own beside the recorder's (`DeviceLink` with a `TVDriver`), told the same things --
/// the app coming back, the network changing -- and answering to a host of its own (`TVHost`), so that neither
/// device's silence, problem or wait for the local network permission is the other's. Not in the demo, whose
/// recorder is invented: a real television would otherwise answer beside it.
extension AppModel {
    var tvDriver: TVDriver? { tv?.driver as? TVDriver }

    /// What the television is listed as among the devices registered with it.
    static let tvNickname = "BD Bridge"

    /// Said when a registration is turned down because the television's display is off.
    static let tvScreenIsOff = "テレビの画面が消えているため、登録できませんでした。テレビの電源を入れて、放送を映してから、もう一度お試しください。"

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

    /// Lets go of the television's link, and of a wait for the permission it had set going.
    func dropTVLink() {
        tvHost?.stopWaitingForPermission()
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

    /// What was found at an address the reader gave for the television.
    enum TVFound: Equatable {
        /// Nothing answered.
        case nothing
        /// Something answered that is not a television.
        case notATelevision
        /// A television, in standby: it shows its PIN only when it is on.
        case standby(model: String)
        case on(model: String)
    }

    /// Asks the device at `host` what it is, without a registration and without changing anything.
    func findTV(at host: String) async -> TVFound {
        let client = ScalarClient(host: host, transport: surroundings.tvTransport(host),
                                  credentials: surroundings.tvCredentials)
        do {
            let power = try await client.powerStatus(timeout: 5)
            let interface = try await client.interface(timeout: 5)
            guard interface.productCategory == "tv" else { return .notATelevision }
            let model = interface.modelName
            return power == "standby" ? .standby(model: model) : .on(model: model)
        } catch let error as ScalarError where error.failure == .silent || error.failure == .badAddress {
            return .nothing
        } catch {
            return .notATelevision
        }
    }

    /// What became of a registration.
    enum TVRegistered: Equatable {
        /// The television wants its PIN, which it shows on its screen when it is showing a broadcast.
        case pinNeeded
        case registered
        case failed(String)
    }

    /// Registers with the television at `host`: with nothing at first, when it answers by putting its PIN on its
    /// screen, and then with the PIN the reader read there. The client id is made once and kept, so that the PIN
    /// goes with the request that asked for it. Registered, the television is saved and connected to on a link
    /// made afresh: an attach still out on the last one, with the last cookie, ends there.
    func registerTV(at host: String, pin: String?) async -> TVRegistered {
        let credentials = surroundings.tvCredentials
        let clientID = credentials.load()?.clientID ?? tvClientID ?? "BDBridge:\(UUID().uuidString)"
        tvClientID = clientID
        let client = ScalarClient(host: host, transport: surroundings.tvTransport(host), credentials: credentials)
        do {
            let mac = try await client.wakeOnLANAddress(timeout: 5).flatMap(WakeOnLan.normalise)
            switch try await client.register(clientID: clientID, nickname: Self.tvNickname, pin: pin) {
            case .pinNeeded:
                return .pinNeeded
            case .registered:
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
        } catch let error as any DeviceError {
            // Its display went off after it was found on: it shows no PIN then, and turns the request down.
            return .failed(error.failure == .needsPower ? Self.tvScreenIsOff : error.explanation)
        } catch {
            return .failed(String(describing: error))
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
