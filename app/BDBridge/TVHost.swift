import Foundation
import Observation
import RecorderKit

/// The app's side of the television's link (`LinkHost`): what the link tells the app about the television, apart
/// from the recorder's. Its own line for what went wrong, its own keys in the defaults, and its own wait for the
/// local network permission, so that nothing the television does stops or clears the recorder's. The lines of
/// what is under way are the app's one list, the television's marked as its own (`televisionLines`). A host the
/// app has let go of -- the television taken away, registered again, or left for the demo -- writes nothing
/// down for an attach that was still out.
///
/// Most of what a link can tell its host is about a recorder -- its cache, its MAC and where it was read,
/// another recorder taking its place -- and is nothing to a television: those are left empty.
@MainActor
@Observable
final class TVHost: LinkHost {
    /// What went wrong with the television, said beside it in the settings and on the strip.
    var problem: String?
    @ObservationIgnored private weak var model: AppModel?
    /// The link this answers for, set once the link is made.
    @ObservationIgnored weak var link: DeviceLink?
    /// Waits for the local network permission after the television's link ran into it.
    @ObservationIgnored private var accessWatch: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    func beginActivity(_ text: String) -> Activities.Token {
        guard let model else {
            var nowhere = Activities()
            return nowhere.begin(text)
        }
        let token = model.activities.begin(text)
        model.televisionLines.insert(token)
        return token
    }

    func updateActivity(_ token: Activities.Token, to text: String) { model?.activities.update(token, to: text) }

    func endActivity(_ token: Activities.Token) {
        model?.televisionLines.remove(token)
        model?.activities.end(token)
    }

    /// Busy with the television: its own lines only.
    var isBusy: Bool { !(model?.televisionLines.isEmpty ?? true) }
    /// A bulk job holds the recorder's client, not the television's.
    var holdsOffConnect: Bool { false }
    var isDemo: Bool { model?.demo ?? false }
    var cache: GuideStore? { model?.store }
    func cacheForAttempt() async { await model?.openCache() }

    func keepAddress(_ host: String) {
        guard let model, model.tvHost === self, !model.demo else { return }
        model.defaults.set(host, forKey: DefaultsKey.tvHost)
    }

    func keepMAC(_ text: String) {
        guard let model, model.tvHost === self, !model.demo, let mac = WakeOnLan.normalise(text) else { return }
        model.defaults.set(mac, forKey: DefaultsKey.tvMac)
    }

    var macReadAt: String? { nil }
    func macWasReadAt(_ host: String) {}
    func forgetMac() {}
    func anotherDeviceDescribedItself(wasConnected: Bool) {}
    func cacheMadeOver() async {}
    func cacheCouldNotBeMadeOver() {}
    func sendWhatWaits() async {}
    func reached() async {}
    func anotherAnsweredTheCheck() {}

    func sayNotConnected() {
        problem = Self.notConnected
    }

    static let notConnected = "テレビに接続していません。テレビの電源とネットワーク接続を確認してください。"

    func waitForPermission(at host: String) {
        accessWatch?.cancel()
        accessWatch = Task { [weak self] in
            let allowed = await LocalNetwork.waitForAccess(probing: host) {}
            guard let self, !Task.isCancelled else { return }
            // cleared before the link connects, since connecting stops whatever wait is still set
            self.accessWatch = nil
            await self.link?.permissionArrived(allowed, at: host)
        }
    }

    func stopWaitingForPermission() {
        accessWatch?.cancel()
        accessWatch = nil
    }
}
