import Foundation
import Network
import RecorderKit
import SwiftUI
import UserNotifications

/// The model's side of the connection to the recorder. What is asked of the recorder, when, and what silence
/// leaves behind is RecorderKit's (`DeviceLink`, `RecorderDriver`); what is here is the app's: the lines on the
/// screen, what the phone keeps, the lists it holds of what the recorder said, the wait for the local network
/// permission, the network watcher, and coming and going from the foreground. The rules are set out in
/// docs/porting.md (端末側の設計メモ) and held by `SessionRuleTests`.
extension AppModel {
    /// Asks again when the network underneath changes, and only then. `NWPathMonitor` reports rather more
    /// than that -- an interface going up on its own account, a route changing -- so the decision is left to
    /// the addresses this device holds, which is what actually says whether the recorder might be nearby.
    func watchNetwork() {
        guard pathMonitor == nil, surroundings.reachesTheLAN else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        // Weak here as well as in the task: the monitor, which the model holds, keeps this handler, and a
        // handler that names `self` only inside the task still holds it strongly.
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.networkReported() }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    /// Connects, and wakes the recorder first if that is what it needs (`DeviceLink.connect`).
    func connect() async {
        await recorder.connect()
    }

    /// What the strip says while `anotherTookOver` is set and the app is connected. Nobody need have asked
    /// for anything -- a change of network asks the recorder whether it is still there -- so it says what to
    /// do if something was being done, not that something was not.
    static let anotherTookOverLine = "別のレコーダーが応答したため、一覧を読み直しました。"
        + "操作の途中だった場合は、確かめてからやり直してください。"

    /// True once a MAC is known, which is what a magic packet needs.
    var canWake: Bool { session.canWake }

    /// Keeps a MAC for waking the recorder, as its host does (`RecorderHost.remember`). Whether it was kept.
    @discardableResult
    func remember(mac text: String) -> Bool { recorderHost.remember(mac: text) }

    func forgetMac() { recorderHost.forgetMac() }

    /// The app has stopped being active, or is active again (`ScenePhase`): told at each change, in the turn
    /// it happens and so in order. Nothing goes by it. A scan for a recorder that is under way writes it to
    /// its log (`ScanLog`), where what the system's question about the local network did to the app can be
    /// read afterwards beside how the scan's requests came back. What coming back from the background is
    /// worth is `returnedToForeground`'s to say, as before.
    func activeChanged(to active: Bool) {
        guard active != appIsActive else { return }
        appIsActive = active
        if scanTask != nil { surroundings.scanLog("phase: \(active ? "active" : "not active")") }
    }

    /// The app has gone to the background, which is what makes coming back worth a reconnect. Only this
    /// counts: Control Centre, the app switcher or a system alert take the app out of `.active` without it
    /// going anywhere, and reconnecting after each sent a magic packet for a glance at the time.
    func wentToBackground() {
        inBackground = true
        if scanTask != nil { surroundings.scanLog("phase: background") }
        // The line about the queue was for this visit, the television's half of it with the recorder's. Coming
        // back sends the queue again when there is anything to send, and says what became of that. So was the
        // one about another recorder.
        closeQueueReport()
        anotherTookOver = false
        // The slot's read again goes with the app: made after a return, it would come beside the return's own
        // reads. A return that makes no attach leaves it for later again, and the disk known stays as it was read
        // until then.
        recorder.setTheReadLeftForLaterAside()
    }

    /// The app is active again. The recorder may have gone to sleep meanwhile, and connecting again also sends
    /// anything queued. What coming back is worth is the link's to say (`DeviceLink.returned`).
    func returnedToForeground() async {
        let wasAway = inBackground
        inBackground = false
        // A bulk job waiting between two steps goes on, and makes sure of the recorder itself first.
        backInFront?.resume()
        backInFront = nil
        // Before any of the reasons not to connect: a day may have gone by while the app was away, with or
        // without a recorder to ask.
        if followTheClock() { await reloadFromCache() }
        // The television's beside the recorder's, so that neither waits for the other's silence, each busy with
        // its own work only.
        let recorderBusy = isBusy, televisionBusy = tvHost?.isBusy ?? false
        let television = Task { await self.tv?.returned(wasAway: wasAway, busy: televisionBusy) }
        await recorder.returned(wasAway: wasAway, busy: recorderBusy)
        await television.value
    }

    /// The watcher's report of the network, looked at again for a while (`DeviceLink.networkReported`), by each
    /// device's link.
    func networkReported() {
        recorder.networkReported()
        tv?.networkReported()
    }

    /// One look at the network (`DeviceLink.networkChangedWhileOpen`): whether it led to an attempt, or to
    /// making sure of the recorder.
    @discardableResult
    func networkChangedWhileOpen() async -> Bool {
        await recorder.networkChangedWhileOpen()
    }

    // MARK: - what the link reaches beyond the recorder

    /// The LAN as the link sees it: the requests go where `surroundings` sends them, and the packet, the
    /// permission's probe and the search for a moved recorder only where the model may put anything on the
    /// network by itself, and never in the demo, whose invented recorder is the one kept for as long as it lasts.
    /// Weak: a link's own tasks can outlast the model, and then reach nothing.
    func linkEnvironment() -> LinkEnvironment {
        LinkEnvironment(
            transport: { [weak self] host in
                guard let self else { return Unreachable() }
                guard self.demo else { return self.surroundings.transport(host) }
                return self.theDemoRecorder()
            },
            networkSignature: { [weak self] in self?.surroundings.networkSignature() ?? "" },
            sendPacket: { [weak self] mac, host in
                // nothing to wake in the demo, and no reason to shout on somebody's LAN
                guard let self, !self.demo, self.surroundings.reachesTheLAN else { return }
                _ = WakeOnLan.wake(mac, addresses: WakeOnLan.addresses(forRecorderAt: host))
            },
            lanIsBlocked: { [weak self] host in
                // Only after a real recorder was silent, and never in the demo (three seconds at most).
                guard let self, !self.demo else { return false }
                return await self.surroundings.linkIsBlocked(host)
            },
            hostsNear: { [weak self] host in
                // Never in the demo or in the background, and only on a Wi-Fi whose subnet `host` belongs to.
                guard let self, !self.demo, !self.inBackground, self.surroundings.reachesTheLAN else { return [] }
                return LocalNetwork.hostsToScan(near: host)
            },
            findRecorder: { mac, hosts in await Discovery.find(mac: mac, among: hosts) },
            slotReadAgainAfter: surroundings.slotReadAgainAfter,
            slotSettling: surroundings.slotSettling)
    }

    /// What the link has until the model is made: nothing reaches anything.
    static var nowhere: LinkEnvironment {
        LinkEnvironment(transport: { _ in Unreachable() }, networkSignature: { "" }, sendPacket: { _, _ in },
                        lanIsBlocked: { _ in false }, hostsNear: { _ in [] }, findRecorder: { _, _ in nil })
    }

    // MARK: - notifications

    func readNotifications() async {
        notifications = await Notify.status()
    }

    /// The system's dialog, when the reader has not answered it yet. See `Notify.askIfNeeded`.
    func askForNotifications() async {
        guard surroundings.asksAboutNotifications else { return }
        await Notify.askIfNeeded()
        await readNotifications()
    }
}

/// What the recorder's host reaches the model for, and the names the screens and the tests call it by.
extension AppModel {
    /// Busy with the recorder: anything under way but the television's lines (`RecorderHost.isBusy`).
    var isBusy: Bool { recorderHost.isBusy }

    /// What waits for the recorder, sent as an attach sends it (`RecorderHost.sendWhatWaits`).
    func sendWhatWaits() async { await recorderHost.sendWhatWaits() }

    /// The warning the runs with no screen left of reservations not yet at the recorder is taken away once a
    /// sending of the app's own, or a delete, leaves none of them waiting to go, and they are told of no more:
    /// the television's rule in the recorder's words (`forgetTheWarningOnceSent`,
    /// `TVTold.afterTheScreensSent`). Asked after each of them: what waits sent (`sendWhatWaits`), a row sent
    /// again (`resend`), a reservation made by hand, which takes the place of a row that waited for its
    /// programme (`reserve`), and a waiting row deleted (`deleteWaiting`). Not in the demo, whose queue is not
    /// the one the warning was about.
    func forgetTheRecordersWarningOnceSent() async {
        guard !demo, let saved = defaults.data(forKey: DefaultsKey.recorderTold),
              let told = try? JSONDecoder().decode(TVTold.self, from: saved),
              let store, let waiting = try? await store.pendingReservations(),
              let after = told.afterTheScreensSent(waiting: waiting, words: .recorder),
              let kept = try? JSONEncoder().encode(after) else { return }
        defaults.set(kept, forKey: DefaultsKey.recorderTold)
        if surroundings.asksAboutNotifications { await Notify.recorder(notYet: nil, withdraws: true) }
    }
}

/// What a link's client gets once the model that made it is gone: silence.
private actor Unreachable: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw RecorderError.transport("The model is gone.")
    }
}
