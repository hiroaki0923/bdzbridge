import Foundation
import Network
import RecorderKit
import SwiftUI
import UserNotifications

/// Connecting to the recorder and staying connected: the first probe, waking it, looking for it at
/// another address, what silence leaves behind, making sure of it before an operation, and when the app
/// asks again -- on coming back, and when the network changes. The rules are set out in docs/porting.md
/// (端末側の設計メモ) and held by `SessionRuleTests`.
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

    /// Connects, and wakes the recorder first if that is what it needs. A BDZ-FBT4100 leaves the LAN when
    /// it has been idle a while and then answers nothing at all, which is below the network standby that
    /// `X_PowerControl` can reach: only a magic packet gets it back. Nobody has to ask for that, so it
    /// happens here rather than as a button — the address came from the recorder itself, the packet costs
    /// nothing, and the reader only wanted to see their guide.
    func connect() async {
        // Not while a bulk job or the duplicate scan is running. It holds the client it started with, and a
        // new one beside it is two queues talking at once to a recorder that answers 503 to the second --
        // which the connect took for a device that is not a recorder and gave up on, putting "not connected"
        // over a job that was still going. Here rather than at the callers, so that 再接続 and pulling down
        // are held off as well. The job makes sure of the recorder by itself, and stops at the first silence.
        guard !host.isEmpty, !connecting, !jobRunning else { return }
        // A check already waking this recorder with the client in hand is doing what this would do, and a
        // second client beside it would talk over it. Asked for meanwhile -- by pulling down, which is what a
        // screen of lists waiting on the waking invites -- this waits for its answer rather than start again.
        if let wakeCheck, let client, client.host == host {
            _ = await wakeCheck.value
            return
        }
        connecting = true
        defer { connecting = false }
        // This attempt answers what the watcher was waiting to find out, one way or the other.
        accessWatch?.cancel()
        accessWatch = nil
        // The cache first, since the queued reservations and the guide are sent from and fetched into it.
        // Coming to the foreground connects too, and at launch it can get here before `start()` has opened
        // anything; without this that connect found no cache and quietly did neither.
        await openCache()
        guard var reached = await reachTheRecorder() else { return }
        // The network under this phone can change while a connect is under way -- the Wi-Fi joined on the way
        // in through the door, a VPN coming up -- and the watcher that would ask again on a change stays out of
        // a connect's way (`networkChangedWhileOpen`). What was tried was then tried on a network that had
        // gone, and the app gave up on the one that had come instead, with nothing to ask again until the
        // reader did. So a connect that got nowhere tries once more, here, when the network it started on is
        // no longer the one under it. Once: a network still changing after that is left to the next return
        // to the app, which asks again on a network it has not tried.
        if LinkRules.triesOnceMore(reached: reached, networkChanged: networkChanged) {
            guard let again = await reachTheRecorder() else { return }
            reached = again
        }
        // Trying again by itself would only spend another half-minute arriving at the same silence. The
        // reader has "再接続" and "レコーダーを探す" for when they know something has changed, and a change of
        // network asks again without being told to.
        // Only silence, though. A recorder that answered, if only to refuse -- a 503 because something else
        // was talking to it, a fault from a model without one of the calls -- is there, and has said what is
        // wrong already. Giving up on it put "not connected" on screen beside a recorder that was answering,
        // and kept the next return to the app from asking again.
        gaveUp = LinkRules.givesUp(reached: reached, silent: unreachable)
        if reached {
            // Provisional permission for notifications, now that there is a recorder for them to be about.
            // No dialog, so nothing lands on the local network question just answered; see `Notify`. Not
            // for the demo, whose recorder nobody will hear from overnight.
            if !demo, surroundings.asksAboutNotifications {
                Task {
                    await Notify.allowQuietly()
                    await readNotifications()
                }
            }
            // Before the guide, because the guide marks what is already set to record and the marks come
            // from this list. Reading it only when the reservations screen appeared meant that opening the
            // app on the guide -- which is where it opens -- showed a programme as unreserved until you had
            // been to the other tab and back.
            await loadReservationsNow()
            await refreshGuideIfStale()
        }
    }

    /// One attempt at the recorder, for `connect()`: a client of its own, the first probe, waking it, and a
    /// look for it at another address. Returns whether it answered, or nil when local network privacy is why
    /// it did not, and the app is now waiting for the permission instead.
    ///
    /// The order of the attempt is `Reach.run`'s, which the check before an operation and the overnight run
    /// follow too. What each step does on the way -- the lines on the strip, reading what the recorder says
    /// about itself -- is here.
    private func reachTheRecorder() async -> Bool? {
        let client: RecorderClient
        if demo {
            let recorder = demoRecorder ?? DemoRecorder()
            demoRecorder = recorder
            client = RecorderClient(host: host, transport: recorder)
        } else {
            client = RecorderClient(host: host, transport: surroundings.transport(host))
        }
        self.client = client
        // The first ask is a short one. A recorder that has left the network does not refuse the
        // connection, it says nothing, so a patient timeout means half a minute of silence before anything
        // can be done about it — and that silence looked like the waking never happened.
        // The packet is a hundred bytes and the probe takes five seconds to fail, so send it now rather
        // than after: a recorder that is asleep is already on its way up while the first probe runs, and one
        // that is awake ignores it. Waiting for the failure first is what made this look like a fault
        // followed by a retry.
        let outcome = await Reach.run(Reach.Steps(
            sendPacket: {
                self.sendMagicPacket()
                self.link.tried(on: self.surroundings.networkSignature())
            },
            probe: {
                await self.attach(client, timeout: RecorderClient.probeTimeout, quiet: self.canWake)
                    ? nil : self.whyNotAttached
            },
            blocked: {
                if self.demo { return false }
                return await self.lanIsBlocked()
            },
            wake: {
                // The permission was not why, or was not asked about: either way the app is not waiting on it.
                self.connectBlocked = false
                return await self.wakeAndAttach(client) ? nil : self.whyNotAttached
            },
            // Not back where it was after the waking: it may be answering at another address. One look per
            // attempt, and only from here, so the rule in `connect()` about not trying again stands.
            elsewhere: {
                guard let moved = await self.findMovedRecorder() else { return .silent }
                self.host = moved.host
                // It is the recorder the MAC was read from, which its UDN has just said.
                self.defaults.set(moved.host, forKey: DefaultsKey.recorderMacHost)
                let found = RecorderClient(host: moved.host, transport: self.surroundings.transport(moved.host))
                self.client = found
                return await self.attach(found, timeout: RecorderClient.probeTimeout) ? nil : self.whyNotAttached
            }))
        if outcome == .blocked {
            waitForPermission()
            return nil
        }
        connectBlocked = false
        return outcome == .answered
    }

    /// Why the `attach` that has just failed did, as `Reach` asks it: silence, or something that answered.
    private var whyNotAttached: DeviceFailure {
        unreachable ? .silent : .refused(reason: problem ?? "")
    }

    /// Whether local network privacy is why the recorder said nothing. Aimed at the recorder's own address,
    /// because that is the connection the permission would have stopped. At most two seconds; the path
    /// answers at once in practice. Only asked in the foreground, after a real recorder was silent -- never
    /// by the overnight run, which has no screen to explain it on, and never in the demo, which has to go
    /// through without the system's question ever coming up.
    private func lanIsBlocked() async -> Bool {
        guard surroundings.reachesTheLAN else { return false }
        return await LocalNetwork.access(probing: host) == .blocked
    }

    /// Silence because iOS stopped the app asking, not because the recorder is asleep. The magic packet
    /// could not leave this phone either, so half a minute of waking would be half a minute of nothing
    /// followed by the wrong advice. Waits for the permission instead; what the screens say comes from
    /// `connectBlocked`, not from a failure line.
    private func waitForPermission() {
        connectBlocked = true
        problem = nil
        gaveUp = true
        watchForAccess()
    }

    /// Waits for the reader to allow the local network, then connects. The one exception to leaving a
    /// recorder alone until the network changes or the reader asks: switching the permission on is the
    /// reader asking, and it changes nothing `networkChanged` could see, so without this the app would stay
    /// given up after it until something else happened to move.
    private func watchForAccess() {
        accessWatch?.cancel()
        let host = host
        accessWatch = Task { [weak self] in
            let allowed = await LocalNetwork.waitForAccess(probing: host) {}
            guard let self, !Task.isCancelled else { return }
            // cleared before connecting, since connecting cancels whatever watcher is still set
            self.accessWatch = nil
            self.connectBlocked = false
            if allowed, self.host == host { await self.connect() }
        }
    }

    /// Reads what the recorder says about itself. Sets `unreachable` when nothing answered at all, which
    /// is the only case worth sending a magic packet for.
    ///
    /// Only the description decides whether this is a recorder the app is connected to. The firmware, the
    /// MAC and the free space are read too, but the app is as connected without them, and another model of
    /// the series may refuse one or answer it in a shape of its own. Failing on that failed the connect
    /// with the recorder answering and described in the settings: an error on screen, the queue not sent,
    /// the reservations and the guide never fetched, and a tutorial that waited for the recorder to be
    /// reached stayed open. What such a read cannot give is left unknown instead
    /// (`RecorderError.silenceOnly`). Silence still ends it, as it would anywhere.
    ///
    /// `quiet` keeps a failure off the screen. A probe that is about to be answered with a magic packet has
    /// not failed at anything the reader should be told about, and saying so for the five seconds before the
    /// waking starts reads as a fault that then mysteriously heals.
    ///
    /// `what` is nil for a probe inside a sequence that has already said what it is doing. Setting and
    /// clearing it per attempt made every button bound to `busy` flicker once a second while waking.
    private func attach(_ client: RecorderClient, what: String? = "接続中",
                        timeout: TimeInterval? = nil, quiet: Bool = false) async -> Bool {
        // A line of its own, and only that one taken away afterwards: this can run inside the waking, which
        // goes on for the better part of a minute and should not lose its line on the screen.
        let activity = what.map { activities.begin($0) }
        defer { if let activity { activities.end(activity) } }
        do {
            info = try await client.describe(timeout: timeout)
            // the overnight run reads the address from here and has no screen to ask, so make sure an
            // address that works is written down however it arrived
            defaults.set(host, forKey: DefaultsKey.recorderHost)
            firmware = try await RecorderError.silenceOnly { try await client.firmwareVersion() } ?? ""
            // Kept for waking it later. The recorder is the only place this can come from on iOS, which
            // cannot read an ARP table, so it is read every time rather than once. With the address it was
            // read at, which is what lets the recorder be recognised by it somewhere else: see
            // `findMovedRecorder`. Not the demo's, which is at an address that is nobody's.
            if let settings = try await RecorderError.silenceOnly({ try await client.networkSettings() }),
               remember(mac: settings.mac), !demo {
                defaults.set(host, forKey: DefaultsKey.recorderMacHost)
            }
            storage = try await Self.storage(of: client)
            unreachable = false
            problem = nil
            await flushPending()
            // The recorder can go quiet in the middle of sending the queue, which leaves the app offline
            // like any other silence; a connect that ended there has not reached anything to show.
            guard !unreachable else { return false }
            timesAttached += 1
            return true
        } catch {
            let recorderError = error as? RecorderError
            unreachable = recorderError?.unreachable ?? false
            // Nothing answered, so we are not connected, whatever a description read earlier says. Leaving
            // it standing is what had the screens asking a recorder that was not there, one 30-second
            // timeout at a time.
            if unreachable { info = nil }
            // Nor is a recorder there if the address is not an address. Leaving the last one's description
            // standing would have the app look connected, to a recorder it is no longer set to.
            if case .badAddress? = recorderError { info = nil }
            // Quiet only keeps silence off the screen, because only silence is answered with a magic packet.
            // Anything else -- an address that is not one, above all -- is where this ends, and without a
            // word the reader would have nothing but a strip saying it is not connected.
            if !quiet || !unreachable { problem = recorderError?.explanation ?? String(describing: error) }
            return false
        }
    }

    /// The free space as the screens show it, or nil when the recorder will not say: see `attach`. A disk
    /// of no size counts as not saying, since the screens would show it as 残り 0 GB -- a full disk, which is
    /// the one thing it is not known to be. Throws only silence.
    private static func storage(of client: RecorderClient) async throws -> (free: Int, total: Int)? {
        guard let capacity = try await RecorderError.silenceOnly({ try await client.recordDestinationInfo() }),
              capacity.totalBytes > 0 else { return nil }
        return (capacity.freeBytes, capacity.totalBytes)
    }

    /// The free space read again, after a delete or with the list of recordings. It is only shown, so a
    /// recorder that will not say is not an error: the read used to be part of the delete, and failing it
    /// put an error on screen, and reported the delete as failed, for a recording that had gone. Silence
    /// is still silence, whatever was being asked.
    func refreshStorage(_ client: RecorderClient) async {
        do {
            storage = try await Self.storage(of: client)
        } catch {
            lostTheRecorder()
        }
    }

    /// Sends the packet, if there is a MAC to send it to. Nothing acknowledges it, so nothing is returned.
    private func sendMagicPacket() {
        if demo { return }   // nothing to wake, and no reason to shout on somebody's LAN
        guard let mac, surroundings.reachesTheLAN else { return }
        _ = WakeOnLan.wake(mac, addresses: WakeOnLan.addresses(forRecorderAt: host))
    }

    /// The magic packet, then waiting for the recorder to answer. Nothing acknowledges the packet, so the
    /// only way to know is to keep asking; a BDZ-FBT4100 is back in about ten seconds.
    @discardableResult
    func wakeAndAttach(_ client: RecorderClient? = nil) async -> Bool {
        guard let client = client ?? self.client, unreachable, mac != nil else { return false }
        sendMagicPacket()   // again: connect() sends one too, and a second costs nothing
        // Nothing is wrong yet, so nothing should be on screen saying there is. The probe that got us here
        // was quiet for the same reason, and each attempt below is too: waking takes a few tries, and a
        // failure line appearing and vanishing between them says the wrong thing.
        problem = nil
        waking = true
        let activity = activities.begin(Self.wakingLine(0))
        defer { waking = false; activities.end(activity) }
        // The line says how long it has been, because a spinner that has been going for twenty seconds is
        // otherwise indistinguishable from a hung one. The wait itself is RecorderKit's, shared with the
        // overnight run and the Shortcuts action (`Waking`).
        //
        // It goes on whatever becomes of the caller, in a task of its own. `connect()` is also what pulling
        // down the list does, and a pull abandoned half way, stopping the wait, would leave the app given up
        // on a recorder that was coming up. The loop this replaced went on too, only without sleeping.
        let outcome = await Task {
            await Waking.waitForAnswer(from: client, limit: Waking.screenLimit,
                                       resend: { @MainActor in self.sendMagicPacket() },
                                       waited: { @MainActor seconds in
                                           self.activities.update(activity, to: Self.wakingLine(seconds))
                                       })
        }.value
        if outcome == .answered {
            return await attach(client, what: "接続中", timeout: RecorderClient.probeTimeout)
        }
        problem = "レコーダーが応答しません。電源とネットワーク接続を確認してください。"
        return false
    }

    private static func wakingLine(_ seconds: Int) -> String {
        "レコーダーを起動しています（\(seconds) 秒）"
    }

    // MARK: - a recorder that is not where it was

    /// Looks for the recorder at another address, once, after waking it where it was came to nothing.
    ///
    /// The recorder's address is a DHCP lease, and the router hands it out again as it likes: after a power
    /// cut, a restart of the router, a long sleep. The app went on knocking at the old address, and the only
    /// thing on screen was 再接続, which knocked there again. The magic packet has already gone to the
    /// subnet's broadcast, so a recorder that moved has had the half minute of waking to come up at its new
    /// address, and a scan of the subnet finds it in a few seconds. It is told from any other recorder by the
    /// MAC kept for waking it, which is the tail of its UDN (`RecorderDescription.hasMAC`), so an
    /// installation that has only ever saved the MAC finds it too.
    ///
    /// Only from `connect()`, once, and never on a loop: when nothing is found the app gives up as before,
    /// until the network changes or the reader asks. Only on a Wi-Fi whose subnet the saved address belongs
    /// to, which is where DHCP would have moved it (`LocalNetwork.hostsToScan(near:)`). Never in the demo, and
    /// never in the background, where the system refuses the local network without a word. The permission
    /// itself has been looked at already: a connect that met silence asks it about the saved address, in this
    /// same subnet, before waking anything, and waits for it rather than coming here.
    private func findMovedRecorder() async -> RecorderDescription? {
        guard !demo, !inBackground, surroundings.reachesTheLAN, let mac, macWasReadHere else { return nil }
        let hosts = LocalNetwork.hostsToScan(near: host)
        guard !hosts.isEmpty else { return nil }
        // The waking's failure is not the last word yet, and a screen saying it while the search runs would
        // be saying it too soon. It is put back if the search finds nothing either.
        let failure = problem
        problem = nil
        waking = true
        let activity = activities.begin("レコーダーを探しています")
        defer { waking = false; activities.end(activity) }
        let moved = await Discovery.find(mac: mac, among: hosts)
        if moved == nil { problem = failure }
        return moved
    }

    /// Whether the MAC is the one the recorder at the saved address reported, or nobody knows (a version
    /// before this one did not write down where). Once the reader has typed the address of another recorder,
    /// the MAC is still the old one's until the new one answers, and the magic packet addressed to it wakes
    /// the old recorder: the search would find that, and quietly go back to the recorder the reader had just
    /// left.
    private var macWasReadHere: Bool {
        guard let readAt = defaults.string(forKey: DefaultsKey.recorderMacHost) else { return true }
        return readAt == host
    }

    // MARK: - a recorder that falls asleep while the app is open

    /// Leaves the app where a connect that got no answer leaves it: not connected, given up until the network
    /// changes or the reader asks, with 再接続 on the strip.
    ///
    /// Every request that meets silence comes here, not only connecting. Before, the rest put the failure on
    /// screen and the app went on looking connected to a recorder that had gone to sleep: the next screen
    /// asked again and waited out the same timeout, nothing offered to reconnect, and pulling down asked the
    /// silent recorder once more instead of connecting.
    ///
    /// Nothing is sent again from here, and the callers do not send again either, not even once the recorder
    /// has been woken: a write that met silence may have reached the recorder all the same, and a reservation
    /// sent twice can be made twice. The reader is told to look once it is back.
    ///
    /// Where the app tried is left as it was, which is where the connect or the check before this began. Put
    /// down as the network the silence ended on, a Wi-Fi that went while the request was out and came back
    /// before it timed out was recorded as tried, and the app gave up at home on a recorder that was answering.
    /// When the network did move meanwhile, the silence may be its doing rather than the recorder's, and the
    /// looks that followed its report may have run out while this waited, so they are set going again. Leaving
    /// home with a request out therefore costs one connect on the way out, as leaving with the app idle does
    /// (`networkChangedWhileOpen`); that is the price of not giving up at home, and not a retry to take out.
    func lostTheRecorder() {
        unreachable = true
        info = nil
        gaveUp = true
        if link.sawAnotherNetwork { networkReported() }
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
    /// is not. Returns whether it is there to ask. When it is not, the app has been left offline, `problem`
    /// says why, and nothing has been sent.
    ///
    /// Without this, a recorder that had gone to sleep while the app was open was found out by the request
    /// itself: thirty seconds on the conflict check, thirty more on the reservation, and then
    /// "送信待ちにしました" on a phone in the same room as the recorder. Now it is asked first, briefly, and
    /// woken the way connecting wakes it -- with the client already in hand. Connecting again would make a
    /// second client, and two clients are two queues talking over each other to a recorder that answers 503
    /// to the second.
    ///
    /// `evenIfRecent` asks whatever the time since the last answer, for when that answer no longer says
    /// anything: the network under this device has changed since.
    func wakeIfDozing(evenIfRecent: Bool = false) async -> Bool {
        guard let client, !offline else {
            problem = notConnected
            return false
        }
        // Already at it: a connect, or the waking of an earlier check -- whose attach reads lists of its own
        // through here, and must not wait for itself. Whatever is asked meanwhile waits behind it in the
        // client's queue.
        if connecting || waking { return true }
        if let wakeCheck { return await wakeCheck.value }
        let check = Task { await self.makeSureItIsUp(client, evenIfRecent: evenIfRecent) }
        wakeCheck = check
        let answered = await check.value
        if wakeCheck == check { wakeCheck = nil }
        return answered
    }

    private func makeSureItIsUp(_ client: RecorderClient, evenIfRecent: Bool) async -> Bool {
        // Only when it has been quiet long enough to have gone to sleep (`LinkRules.dozeAfter`).
        if !LinkRules.needsCheck(lastAnswer: await client.lastAnswer, now: Date(), evenIfRecent: evenIfRecent) {
            return true
        }
        // Where it was asked, not where the phone is once the silence is over: see `lostTheRecorder`.
        let network = surroundings.networkSignature()
        // The packet first and the probe after, as connecting does (`Reach.run`): a recorder that is asleep
        // is on its way up while the probe waits, and one that is awake ignores it. It is not looked for at
        // another address from here: only a connect does that.
        var answeredTheProbe = true
        let outcome = await Reach.run(Reach.Steps(
            sendPacket: { self.sendMagicPacket() },
            probe: {
                do {
                    try await client.describe(timeout: RecorderClient.probeTimeout)
                    return nil
                } catch {
                    let failure = (error as? any DeviceError)?.failure ?? .unexpected(String(describing: error))
                    if failure == .silent {
                        // Silence, which is what waking is for. Where a connect's first probe leaves things
                        // too, and what waking starts from.
                        answeredTheProbe = false
                        self.unreachable = true
                        self.info = nil
                        self.link.tried(on: network)
                    }
                    return failure
                }
            },
            blocked: {
                if self.demo { return false }
                return await self.lanIsBlocked()
            },
            wake: { await self.wakeAndAttach(client) ? nil : self.whyNotAttached }))
        switch outcome {
        case .answered:
            return true
        case .refused:
            // On the probe: something answered, so there is nothing to wake, and what is wrong is for the
            // request itself to run into and say. After the waking: it answered only to refuse, which the
            // attach has said already; it is not silence, so it is not given up on either (see `connect()`).
            return answeredTheProbe
        case .blocked:
            waitForPermission()
            return false
        case .silent:
            // Given up, as a connect is when waking does not bring the recorder back.
            lostTheRecorder()
            // Waking says why it gave up; without a MAC there was no waking to say it.
            if !canWake { problem = RecorderError.transport("no answer").explanation }
            return false
        }
    }

    /// True once a MAC is known, which is what a magic packet needs. Until then there is nothing to send:
    /// the address cannot be guessed and iOS will not read the ARP table.
    var canWake: Bool { mac != nil }

    /// Keeps a MAC for waking the recorder. Anything that is not one is ignored rather than stored, so a
    /// half-typed address never replaces a good one. Returns whether it was kept.
    @discardableResult
    func remember(mac text: String) -> Bool {
        guard let normalised = WakeOnLan.normalise(text) else { return false }
        mac = normalised
        defaults.set(normalised, forKey: DefaultsKey.recorderMac)
        return true
    }

    func forgetMac() {
        mac = nil
        defaults.removeObject(forKey: DefaultsKey.recorderMac)
        defaults.removeObject(forKey: DefaultsKey.recorderMacHost)
    }

    /// The app has gone to the background, which is what makes coming back worth a reconnect. Only this
    /// counts. Control Centre, Notification Centre, the app switcher and a system alert take the app out of
    /// `.active` as well, without it going anywhere, and reconnecting after each of them sent a magic packet
    /// for a glance at the time -- and, with a bulk job running, set a second client talking over the job's.
    func wentToBackground() {
        inBackground = true
        // The line about the queue was for this visit. Coming back sends the queue again when there is
        // anything to send, and says what became of that.
        flushReport = nil
    }

    /// The app is active again. The recorder may have gone to sleep while it was away -- a BDZ-FBT4100 leaves
    /// the network after a quarter of an hour or so -- and the screens would otherwise show what was true
    /// when the app was last looked at. Connecting again also sends anything queued. Called every time the
    /// scene becomes active, and connects only when the app has really been away: see `wentToBackground`.
    func returnedToForeground() async {
        let wasAway = inBackground
        inBackground = false
        // A bulk job waiting between two steps goes on, and makes sure of the recorder itself first.
        backInFront?.resume()
        backInFront = nil
        // Before any of the reasons below not to connect: a day may have gone by while the app was away,
        // with or without a recorder to ask.
        if followTheClock() { await reloadFromCache() }
        // What coming back is worth is `LinkRules.onReturn`'s to say. In short: nothing after a moment in
        // Control Centre and the like, which went nowhere (see `wentToBackground`). While something is under
        // way, or a check is making sure of the recorder, connecting would make a second client beside the
        // one at work -- the conflict check has no line of its own to make `busy` say so -- but the network
        // may have moved while the app was away all the same, and the looks wait for this. Not on every flick
        // between apps: any answer within the last minute counts, not only the connect's. And not when the
        // recorder was already tried on this very network and said nothing: coming back is not news, and
        // half a minute of waking a recorder that is not there, every time, is what made the app look as
        // though it never stopped searching. It may be news a moment from now, though -- switching the Wi-Fi
        // on in the Settings app and coming straight back is quicker than the phone gets its address -- and
        // the look is what catches it arriving.
        let hasAddress = !host.isEmpty, busyNow = busy != nil, checking = wakeCheck != nil
        // The recorder's last answer is on its own actor, and asking for it gives up this one's turn: asked
        // only where the rule will read it, so that nothing else waits for it. Any answer counts, not only
        // the connect's.
        let asksItsAge = wasAway && hasAddress && !busyNow && !checking && connected
        let lastAnswer = asksItsAge ? await client?.lastAnswer : nil
        switch LinkRules.onReturn(wasAway: wasAway, hasAddress: hasAddress, busy: busyNow, checking: checking,
                                  connected: connected, lastAnswer: lastAnswer, now: Date(), gaveUp: gaveUp,
                                  networkChanged: networkChanged) {
        case .nothing: return
        case .lookAtTheNetwork: networkReported()
        case .connect: await connect()
        }
    }

    /// The watcher's report, which is news of the network but not yet the network. iOS reports a path as
    /// soon as it can be used -- on a network with IPv6 as well, before the phone has its IPv4 address there
    /// -- and says nothing more when the address arrives, so looking only when the report came found the
    /// network unchanged and left the app on 接続できません at home. A report can also come while the app is
    /// busy, which the look waits out. So the network is looked at again for a minute after each report,
    /// until something has been done about it. A report of nothing -- a route changing -- costs a few looks at
    /// the addresses and nothing else. The looks last half a minute (`LinkRules.looksAfterAReport`); what
    /// keeps the app busy for longer than that -- a guide file has two minutes -- ends in `lostTheRecorder`
    /// if the network took the recorder away, which sets the looks going again.
    func networkReported() {
        // Now rather than in the first look: by then the Wi-Fi may be back, and that it went at all is lost.
        noteTheNetwork()
        settling?.cancel()
        settling = Task { [weak self] in
            for pause in LinkRules.looksAfterAReport {
                try? await Task.sleep(for: .seconds(pause))
                guard !Task.isCancelled, let self else { return }
                if await self.networkChangedWhileOpen() { return }
            }
        }
    }

    private func noteTheNetwork() {
        link.noted(network: surroundings.networkSignature())
    }

    /// The network changed while the app was open: a different Wi-Fi, the VPN coming up, cellular taking
    /// over. That is the one thing that makes another attempt worth making without being asked. Returns
    /// whether it made one, or made sure of the recorder.
    ///
    /// While connected, it is the one thing that makes the last answer worth nothing: leaving home with the
    /// app open left it looking connected to a recorder it could no longer reach, until something asked and
    /// waited out a timeout. The recorder is asked again with the client in hand, as before an operation.
    @discardableResult
    func networkChangedWhileOpen() async -> Bool {
        // Noted first, busy or not: a Wi-Fi that has gone and come back by the time the app is free to look
        // is still a network the last try was not made on.
        noteTheNetwork()
        switch LinkRules.onNetworkChange(hasAddress: !host.isEmpty, busy: busy != nil,
                                         networkChanged: networkChanged, connected: connected) {
        case .nothing:
            return false
        case .connect:
            // `connect()` returns without trying while another connect or a job is under way, or while a
            // check is waking the recorder; whether it tried is what the count says.
            let before = link.tries
            await connect()
            return link.tries != before
        case .makeSure:
            link.tried(on: surroundings.networkSignature())
            _ = await wakeIfDozing(evenIfRecent: true)
            return true
        }
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
