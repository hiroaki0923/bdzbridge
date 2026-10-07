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

    /// The recordings and the keyword conditions, read from a recorder that has taken the place of another
    /// in the middle of being connected (`anotherDeviceDescribedItself`). The screens read them when the app
    /// becomes connected, and it never stopped being: left to them, the recordings tab said there were none.
    private func readAgainWhatWasUp() async {
        let again = listsToReadAgain
        listsToReadAgain = (false, false)
        if again.recordings { await loadTitlesNow(force: false) }
        if again.rules { await loadRecorderRulesNow() }
    }

    /// Said when the recorder that answered is another one and the cache could not be made over to it: the
    /// database is busy with another writer for longer than it will wait, or cannot be written to.
    static let cacheNotMadeOver = "端末内のデータベースに書き込めなかったため、接続を中断しました。"
        + "少し待ってから、もう一度お試しください。"

    /// Written on each reservation that was waiting when another recorder took the place of the one it was
    /// made for, which holds it as a refusal does (`PendingQueue.flush`). How to send it again is said by the
    /// row's swipe, the programme's sheet and the reservations screen's footer.
    static let heldForAnotherRecorder = "別のレコーダーに切り替わったため、送らずに残しています。"
        + "「もう一度送る」を選ぶと、いまのレコーダーに送ります。"

    /// Said when something the reader asked for was not done because another recorder answered where the
    /// one it was meant for had been. Not only what is sent: a read comes through the same check.
    static let anotherAnswered = "別のレコーダーが応答したため、この操作は行っていません。"
        + "一覧を読み直しますので、確かめてからもう一度お試しください。"

    /// What the strip says while `anotherTookOver` is set and the app is connected. Nobody need have asked
    /// for anything -- a change of network asks the recorder whether it is still there -- so it says what to
    /// do if something was being done, not that something was not.
    static let anotherTookOverLine = "別のレコーダーが応答したため、一覧を読み直しました。"
        + "操作の途中だった場合は、確かめてからやり直してください。"

    /// The free space read again, after a delete or with the list of recordings. It is only shown, so a
    /// recorder that will not say is not an error, and the delete it follows is not reported as failed.
    /// Silence is still silence.
    func refreshStorage(_ client: RecorderClient) async {
        do {
            session.learned(storage: try await RecorderDriver.storage(of: client))
        } catch {
            lostTheRecorder()
        }
    }

    /// Leaves the app where a connect that got no answer leaves it (`DeviceLink.lost`). A request the model
    /// sends by hand comes here when it meets silence; one through the funnel is lost by the link as it says
    /// the failure (`DeviceLink.say`), which comes to the same. Nothing is sent again from here, nor by the
    /// callers once the recorder is back: a write that met silence may have arrived all the same.
    func lostTheRecorder() {
        recorder.lost()
    }

    /// Said when a write met silence. Whether it arrived is not known, which is exactly why it is not sent
    /// again, and what the list says once the recorder answers is the only way to find out.
    static let mayHaveArrived = "送信の途中でレコーダーの応答がなくなりました。届いている場合もあるため、"
        + "送り直していません。再接続してから一覧で確かめてください。"

    /// Why something the reader asked for was not sent at all: the app is not connected.
    var notConnected: String {
        connectBlocked ? LocalNetworkNotice.title
            : "レコーダーに接続していません。「再接続」を押してから、もう一度お試しください。"
    }

    /// Makes sure the recorder is up before something the reader asked for is sent to it, and wakes it if it
    /// is not (`DeviceLink.ensureUp`). When it is not, nothing has been sent, and the app has been left offline
    /// with `problem` saying why, or waiting for the local network permission (`connectBlocked`).
    func wakeIfDozing(evenIfRecent: Bool = false) async -> Bool {
        await recorder.ensureUp(evenIfRecent: evenIfRecent)
    }

    /// True once a MAC is known, which is what a magic packet needs.
    var canWake: Bool { session.canWake }

    /// Keeps a MAC for waking the recorder. Anything that is not one is ignored rather than stored, so a
    /// half-typed address never replaces a good one. Returns whether it was kept.
    @discardableResult
    func remember(mac text: String) -> Bool {
        guard session.remember(mac: text), let normalised = session.mac else { return false }
        defaults.set(normalised, forKey: DefaultsKey.recorderMac)
        return true
    }

    func forgetMac() {
        session.forgetMac()
        defaults.removeObject(forKey: DefaultsKey.recorderMac)
        defaults.removeObject(forKey: DefaultsKey.recorderMacHost)
    }

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
        // reads. The disk known stays as it was read until an attach reads the slot again.
        recorder.endTheReadLeftForLater()
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
                // Kept for as long as the demo lasts, because it holds what the reader has done to it.
                let recorder = self.demoRecorder ?? DemoRecorder(delay: DemoData.answerDelay)
                self.demoRecorder = recorder
                return recorder
            },
            networkSignature: { [weak self] in self?.surroundings.networkSignature() ?? "" },
            sendPacket: { [weak self] mac, host in
                // nothing to wake in the demo, and no reason to shout on somebody's LAN
                guard let self, !self.demo, self.surroundings.reachesTheLAN else { return }
                _ = WakeOnLan.wake(mac, addresses: WakeOnLan.addresses(forRecorderAt: host))
            },
            lanIsBlocked: { [weak self] host in
                // Only after a real recorder was silent, and never in the demo (two seconds at most).
                guard let self, !self.demo, self.surroundings.reachesTheLAN else { return false }
                return await LocalNetwork.access(probing: host) == .blocked
            },
            hostsNear: { [weak self] host in
                // Never in the demo or in the background, and only on a Wi-Fi whose subnet `host` belongs to.
                guard let self, !self.demo, !self.inBackground, self.surroundings.reachesTheLAN else { return [] }
                return LocalNetwork.hostsToScan(near: host)
            },
            findRecorder: { mac, hosts in await Discovery.find(mac: mac, among: hosts) },
            slotReadAgainAfter: surroundings.slotReadAgainAfter)
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

/// What the recorder's link tells the model, and asks of it (`LinkHost`). Every one of these is the app's own
/// state: the lines on the screen, the three keys the runs with no screen read, and the lists the screens hold of
/// what the recorder said.
extension AppModel {
    func beginActivity(_ text: String) -> Activities.Token { activities.begin(text) }
    func updateActivity(_ token: Activities.Token, to text: String) { activities.update(token, to: text) }
    func endActivity(_ token: Activities.Token) { activities.end(token) }

    /// Busy with the recorder: anything under way but the television's lines.
    var isBusy: Bool { activities.any(besides: televisionLines) }
    var holdsOffConnect: Bool { jobRunning }
    var isDemo: Bool { demo }
    var cache: GuideStore? { store }

    /// The cache first: the queue is sent from it and the guide fetched into it, and a connect made on coming to
    /// the foreground can get here before `start()` has opened anything.
    func cacheForAttempt() async {
        listsToReadAgain = (false, false)
        await openCache()
    }

    /// The overnight run reads the address from here and has no screen to ask, so an address that works is
    /// written down however it arrived.
    func keepAddress(_ host: String) {
        defaults.set(host, forKey: DefaultsKey.recorderHost)
    }

    /// With the address it was read at, which lets the recorder be recognised by it elsewhere. Not the demo's.
    func keepMAC(_ text: String) {
        if remember(mac: text), !demo { defaults.set(host, forKey: DefaultsKey.recorderMacHost) }
    }

    var macReadAt: String? { defaults.string(forKey: DefaultsKey.recorderMacHost) }

    func macWasReadAt(_ host: String) {
        defaults.set(host, forKey: DefaultsKey.recorderMacHost)
    }

    /// Another recorder's lists go in the turn its description arrives, and the strip says so: nobody chose it,
    /// or the last one would have been forgotten at the choice. The screens read their lists when the app
    /// becomes connected, and it never stopped being, so what they had read is read again by this connect.
    func anotherDeviceDescribedItself(wasConnected: Bool) {
        let had = (recordings: titlesLoaded, rules: recorderRulesLoaded)
        forgetWhatTheRecorderSaid()
        anotherTookOver = true
        if wasConnected { listsToReadAgain = had }
    }

    /// The guide on screen was the other recorder's, and the rows waiting have a reason on them now. The marks
    /// the defaults keep about its disks and its guide go with it.
    func cacheMadeOver() async {
        defaults.removeObject(forKey: DefaultsKey.warnedLowSpace)
        defaults.removeObject(forKey: DefaultsKey.warnedLowSpaceOnUSB)
        defaults.removeObject(forKey: DefaultsKey.lastBackgroundRefresh)
        await reloadFromCache()
        await loadPending()
    }

    /// It says so, and lets go of the client as well -- left in hand, a programme reserved from the guide still
    /// on screen was sent to this recorder. That another one answered is still to be said once it is taken up.
    func cacheCouldNotBeMadeOver() {
        let another = anotherTookOver
        forgetTheRecorder()
        anotherTookOver = another
        problem = Self.cacheNotMadeOver
    }

    func sendWhatWaits() async {
        await flushPending()
    }

    /// Provisional permission for notifications, now that there is a recorder for them to be about: no dialog,
    /// so nothing lands on the local network question just answered (`Notify`). Not for the demo. Then the
    /// reservations before the guide, which marks what is already set to record from that list.
    func reached() async {
        if !demo, surroundings.asksAboutNotifications {
            Task {
                await Notify.allowQuietly()
                await readNotifications()
            }
        }
        await loadReservationsNow()
        await readAgainWhatWasUp()
        await refreshGuideIfStale()
    }

    /// Its lists go at once, and the newcomer is taken up by a connect of its own, which reads its reservations
    /// and its guide as a waking's attach does not. A job under way was the last recorder's: it is stopped before
    /// its next step, and the connect waits for it to end, since one does not start beside a job. Said twice:
    /// the failure line for whoever asked, which the connect takes away, and the strip after that.
    func anotherAnsweredTheCheck() {
        forgetTheRecorder()
        cancelBulk()
        problem = Self.anotherAnswered
        anotherTookOver = true
        let running = jobTask
        Task {
            await running?.value
            self.clearJob()
            await self.connect()
        }
    }

    func sayNotConnected() {
        problem = notConnected
    }

    /// Waits for the reader to allow the local network, then tells the link. The screens say so from
    /// `connectBlocked`. A wait that has given up with the permission still in the way ends for the link as
    /// one that found no path: it is told the permission did not come, and connecting again is the reader's.
    func waitForPermission(at host: String) {
        accessWatch?.cancel()
        accessWatch = Task { [weak self] in
            let access = await LocalNetwork.waitForAccess(probing: host) {}
            guard let self, !Task.isCancelled else { return }
            // cleared before the link connects, since connecting stops whatever wait is still set
            self.accessWatch = nil
            await self.recorder.permissionArrived(access == .allowed, at: host)
        }
    }

    func stopWaitingForPermission() {
        accessWatch?.cancel()
        accessWatch = nil
    }
}

/// What a link's client gets once the model that made it is gone: silence.
private actor Unreachable: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw RecorderError.transport("The model is gone.")
    }
}
