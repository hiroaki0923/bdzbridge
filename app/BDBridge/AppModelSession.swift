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
    /// `X_PowerControl` can reach: only a magic packet gets it back, so one is sent without being asked for.
    func connect() async {
        // Not while a bulk job or the duplicate scan runs. It holds the client it started with, and a second
        // one beside it is two queues talking to a recorder that answers 503 to the second. Here rather than
        // at the callers, so that 再接続 and pulling down are held off as well.
        guard !host.isEmpty, !connecting, !jobRunning else { return }
        // A check already waking this recorder is doing what this would do, and a second client would talk
        // over it: wait for its answer rather than start again.
        if let wakeCheck, let client, client.host == host {
            _ = await wakeCheck.value
            return
        }
        session.beginConnecting()
        defer { session.endConnecting() }
        listsToReadAgain = (false, false)
        // This attempt answers what the watcher was waiting to find out, one way or the other.
        accessWatch?.cancel()
        accessWatch = nil
        // The cache first: the queue is sent from it and the guide fetched into it, and a connect made on
        // coming to the foreground can get here before `start()` has opened anything.
        await openCache()
        guard var reached = await reachTheRecorder() else { return }
        // The network can change while a connect is under way -- the Wi-Fi joined on the way in through the
        // door -- and the watcher stays out of a connect's way. So a connect that got nowhere tries once more
        // when the network it started on is no longer the one under it. Once: a network still changing is
        // left to the next return to the app.
        if LinkRules.triesOnceMore(reached: reached, networkChanged: networkChanged) {
            guard let again = await reachTheRecorder() else { return }
            reached = again
        }
        // Trying again by itself would only arrive at the same silence; the reader has 再接続 and
        // レコーダーを探す, and a change of network asks again unasked. Only silence is given up on: a recorder
        // that answered, if only to refuse -- a 503, a fault from another model -- is there, and has said
        // what is wrong.
        session.finishedTrying(reached: reached)
        if reached {
            // Provisional permission for notifications, now that there is a recorder for them to be about:
            // no dialog, so nothing lands on the local network question just answered (`Notify`). Not for
            // the demo.
            if !demo, surroundings.asksAboutNotifications {
                Task {
                    await Notify.allowQuietly()
                    await readNotifications()
                }
            }
            // Before the guide, which marks what is already set to record from this list.
            await loadReservationsNow()
            await readAgainWhatWasUp()
            await refreshGuideIfStale()
        }
    }

    /// The recordings and the keyword conditions, read from a recorder that has taken the place of another
    /// in the middle of being connected (`settle(whoAnswered:)`). The screens read them when the app becomes
    /// connected, and it never stopped being: left to them, the recordings tab said there were none.
    private func readAgainWhatWasUp() async {
        let again = listsToReadAgain
        listsToReadAgain = (false, false)
        if again.recordings { await loadTitlesNow(force: false) }
        if again.rules { await loadRecorderRulesNow() }
    }

    /// One attempt at the recorder, for `connect()`: a client of its own, the first probe, waking it, and a
    /// look for it at another address, in the order `Reach.run` keeps. Returns whether it answered, or nil
    /// when local network privacy is why it did not and the app is waiting for the permission instead.
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
        // The first ask is short: a recorder that has left the network says nothing rather than refuse, and
        // a patient timeout is half a minute of silence before anything is done about it. The packet goes
        // first, so that a recorder asleep is on its way up while the probe waits; one awake ignores it.
        let outcome = await Reach.run(Reach.Steps(
            sendPacket: {
                self.sendMagicPacket()
                self.session.tried(on: self.surroundings.networkSignature())
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
                self.session.permissionCleared()
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
        session.permissionCleared()
        return outcome == .answered
    }

    /// Why the `attach` that has just failed did, as `Reach` asks it: silence, or something that answered.
    private var whyNotAttached: DeviceFailure {
        unreachable ? .silent : .refused(reason: problem ?? "")
    }

    /// Whether local network privacy is why the recorder said nothing, asked of the recorder's own address
    /// (two seconds at most). Only from the screens' connect and check, after a real recorder was silent:
    /// never by the overnight run, which has no screen to explain it on, nor in the demo.
    private func lanIsBlocked() async -> Bool {
        guard surroundings.reachesTheLAN else { return false }
        return await LocalNetwork.access(probing: host) == .blocked
    }

    /// Silence because iOS stopped the app asking, not because the recorder is asleep: the magic packet
    /// could not leave either, so waking would be half a minute of nothing. Waits for the permission
    /// instead; the screens say so from `connectBlocked`.
    private func waitForPermission() {
        session.waitingForPermission()
        problem = nil
        watchForAccess()
    }

    /// Waits for the reader to allow the local network, then connects. The one exception to leaving a
    /// recorder alone until the network changes or the reader asks: switching the permission on is the
    /// reader asking, and changes nothing `networkChanged` could see.
    private func watchForAccess() {
        accessWatch?.cancel()
        let host = host
        accessWatch = Task { [weak self] in
            let allowed = await LocalNetwork.waitForAccess(probing: host) {}
            guard let self, !Task.isCancelled else { return }
            // cleared before connecting, since connecting cancels whatever watcher is still set
            self.accessWatch = nil
            self.session.permissionCleared()
            if allowed, self.host == host { await self.connect() }
        }
    }

    /// Reads what the recorder says about itself. Sets `unreachable` when nothing answered at all, which
    /// is the only case worth a magic packet.
    ///
    /// Only the description decides whether the app is connected. The firmware, the MAC and the free space
    /// are read too, but another model may refuse one or answer in a shape of its own, and that must not
    /// fail the connect: what cannot be read is left unknown (`RecorderError.silenceOnly`). Silence still
    /// ends it.
    ///
    /// `quiet` keeps a failure off the screen, for a probe about to be answered with a magic packet. `what`
    /// is nil inside a sequence that has already said what it is doing.
    private func attach(_ client: RecorderClient, what: String? = "接続中",
                        timeout: TimeInterval? = nil, quiet: Bool = false) async -> Bool {
        // A line of its own, and only that one taken away afterwards: this can run inside the waking, which
        // goes on for the better part of a minute and should not lose its line on the screen.
        let activity = what.map { activities.begin($0) }
        defer { if let activity { activities.end(activity) } }
        do {
            // A cache that is another recorder's and could not be made over to this one is no recorder to
            // connect to: the app would go on over the other's guide and texts. It says so, and lets go of
            // the client as well -- left in hand, a programme reserved from the guide still on screen was
            // sent to this recorder. That another one answered is still to be said once it is taken up.
            guard await settle(whoAnswered: try await client.describe(timeout: timeout)) else {
                let another = anotherTookOver
                forgetTheRecorder()
                anotherTookOver = another
                problem = Self.cacheNotMadeOver
                return false
            }
            // the overnight run reads the address from here and has no screen to ask, so make sure an
            // address that works is written down however it arrived
            defaults.set(host, forKey: DefaultsKey.recorderHost)
            session.learned(firmware: try await RecorderError.silenceOnly { try await client.firmwareVersion() } ?? "")
            // Kept for waking it later, and read every time: on iOS the recorder is the only place it can
            // come from. With the address it was read at, which lets the recorder be recognised by it
            // elsewhere (`findMovedRecorder`). Not the demo's.
            if let settings = try await RecorderError.silenceOnly({ try await client.networkSettings() }),
               remember(mac: settings.mac), !demo {
                defaults.set(host, forKey: DefaultsKey.recorderMacHost)
            }
            session.learned(storage: try await Self.storage(of: client))
            session.answered()
            problem = nil
            await flushPending()
            // The recorder can go quiet in the middle of sending the queue, which leaves the app offline
            // like any other silence; a connect that ended there has not reached anything to show.
            guard !unreachable else { return false }
            session.attached()
            return true
        } catch {
            let recorderError = error as? RecorderError
            // Nothing answered, so the app is not connected, whatever a description read earlier says; nor
            // when the address is not an address. Anything else answered, and what is known of the recorder
            // stands (`SessionState.attachFailed`).
            session.attachFailed(recorderError?.failure)
            // Quiet only keeps silence off the screen, since only silence is answered with a magic packet.
            // Anything else is where this ends, and the reader is told.
            if !quiet || !unreachable { problem = recorderError?.explanation ?? String(describing: error) }
            return false
        }
    }

    /// A recorder has said who it is, which decides what the app keeps of the one before it: the same
    /// recorder keeps everything wherever it answers, and another one gets nothing that was the last one's.
    /// Asked at every attach, before anything is read from the recorder or sent to it.
    ///
    /// In memory (`SessionState.described`), another recorder's lists go in the turn its description arrives,
    /// and the strip says so. On the phone (`GuideStore.claim`), its texts, its guide and the queue are seen
    /// to, and with them the two marks the defaults keep about one disk and one guide; the MAC goes unless
    /// this recorder carries it. What was held is said by the sending of the queue that follows.
    ///
    /// False when the cache is another's and could not be made over: the caller does not go on.
    private func settle(whoAnswered recorder: RecorderDescription) async -> Bool {
        let wasConnected = connected
        let had = (recordings: titlesLoaded, rules: recorderRulesLoaded)
        let inMemory = session.described(recorder)
        if inMemory == .another {
            forgetWhatTheRecorderSaid()
            // Nobody chose it, or the last one would have been forgotten at the choice: the strip says so.
            anotherTookOver = true
            // The screens read their lists when the app becomes connected, and it never stopped being.
            if wasConnected { listsToReadAgain = had }
        }
        // The demo's cache is a file of its own, made for the invented recorder and deleted with it.
        guard !demo, let store else { return true }
        // What the session knows goes with it: a cache with no owner written is the last recorder's when the
        // lists were.
        let lastWasAnother = inMemory == .another
        let onDisk: Recognition
        do {
            onDisk = try await store.claim(for: recorder, holdingTheQueueWith: Self.heldForAnotherRecorder,
                                           knownToBeAnother: lastWasAnother)
        } catch {
            // The cache could not be written to. For the recorder it is of, or the first heard from, that
            // costs nothing. Another one's it stays -- by its owner, or by what the session knows -- and one
            // that cannot even be read is nobody's to go on over.
            guard let asked = try? await store.recognises(recorder),
                  asked == .same || (asked == .first && !lastWasAnother) else { return false }
            onDisk = asked
        }
        guard inMemory == .another || onDisk == .another else { return true }
        if let mac, !recorder.hasMAC(mac) { forgetMac() }
        guard onDisk == .another else { return true }
        defaults.removeObject(forKey: DefaultsKey.warnedLowSpace)
        defaults.removeObject(forKey: DefaultsKey.lastBackgroundRefresh)
        // The guide on screen was the other recorder's, and the rows waiting have a reason on them now. An
        // attach that gets no further than this never comes to the sending of the queue, which reads them.
        await reloadFromCache()
        await loadPending()
        return true
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

    /// The free space as the screens show it, or nil when the recorder will not say: see `attach`. A disk
    /// of no size counts as not saying, since the screens would show it as 残り 0 GB -- a full disk, which is
    /// the one thing it is not known to be. Throws only silence.
    private static func storage(of client: RecorderClient) async throws -> (free: Int, total: Int)? {
        guard let capacity = try await RecorderError.silenceOnly({ try await client.recordDestinationInfo() }),
              capacity.totalBytes > 0 else { return nil }
        return (capacity.freeBytes, capacity.totalBytes)
    }

    /// The free space read again, after a delete or with the list of recordings. It is only shown, so a
    /// recorder that will not say is not an error, and the delete it follows is not reported as failed.
    /// Silence is still silence.
    func refreshStorage(_ client: RecorderClient) async {
        do {
            session.learned(storage: try await Self.storage(of: client))
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
        // Nothing is wrong yet, so nothing on screen should say there is: waking takes a few tries, and a
        // failure line appearing and vanishing between them says the wrong thing.
        problem = nil
        session.beginWaking()
        let activity = activities.begin(Self.wakingLine(0))
        defer { session.endWaking(); activities.end(activity) }
        // The line says how long it has been: a spinner twenty seconds old looks hung. The wait itself is
        // RecorderKit's (`Waking`), and goes on in a task of its own whatever becomes of the caller: a pull
        // on the list abandoned half way must not leave the app given up on a recorder that is coming up.
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
    /// The recorder's address is a DHCP lease, which the router hands out again after a power cut or a
    /// restart. The magic packet has gone to the subnet's broadcast, so a recorder that moved has had the
    /// waking to come up at its new address, and a scan finds it in a few seconds. It is told from any other
    /// by the MAC kept for waking it, the tail of its UDN (`RecorderDescription.hasMAC`).
    ///
    /// Only from `connect()`, once: when nothing is found the app gives up as before. Only on a Wi-Fi whose
    /// subnet the saved address belongs to (`LocalNetwork.hostsToScan(near:)`), never in the demo or in the
    /// background. The permission has been looked at already, before the waking.
    private func findMovedRecorder() async -> RecorderDescription? {
        guard !demo, !inBackground, surroundings.reachesTheLAN, let mac, macWasReadHere else { return nil }
        let hosts = LocalNetwork.hostsToScan(near: host)
        guard !hosts.isEmpty else { return nil }
        // The waking's failure is not the last word yet, and a screen saying it while the search runs would
        // be saying it too soon. It is put back if the search finds nothing either.
        let failure = problem
        problem = nil
        session.beginWaking()
        let activity = activities.begin("レコーダーを探しています")
        defer { session.endWaking(); activities.end(activity) }
        let moved = await Discovery.find(mac: mac, among: hosts)
        if moved == nil { problem = failure }
        return moved
    }

    /// Whether the MAC is the one the recorder at the saved address reported, or nobody knows where it was
    /// read (earlier versions did not write that down). After the reader types another recorder's address
    /// the MAC is still the old one's until the new one answers, and the search would quietly go back to
    /// the recorder just left.
    private var macWasReadHere: Bool {
        guard let readAt = defaults.string(forKey: DefaultsKey.recorderMacHost) else { return true }
        return readAt == host
    }

    // MARK: - a recorder that falls asleep while the app is open

    /// Leaves the app where a connect that got no answer leaves it: not connected, given up until the network
    /// changes or the reader asks, with 再接続 on the strip. Every request that meets silence comes here, not
    /// only connecting, so that the screens stop asking a recorder that has gone to sleep.
    ///
    /// Nothing is sent again from here, nor by the callers once the recorder is back: a write that met
    /// silence may have arrived all the same, and a reservation sent twice can be made twice.
    ///
    /// Where the app tried is left as it was. Put down as the network the silence ended on, a Wi-Fi that
    /// went and came back while the request was out counted as tried, and the app gave up at home. When the
    /// network did move meanwhile, the looks that followed its report are set going again.
    func lostTheRecorder() {
        session.lost()
        if session.link.sawAnotherNetwork { networkReported() }
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
    /// Asked first and briefly, so that a recorder asleep is not found out by the request itself, thirty
    /// seconds at a time; woken with the client already in hand, since a second client would be a second
    /// queue talking to a recorder that answers 503 to it. `evenIfRecent` asks whatever the time since the
    /// last answer, for when the network has changed since.
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
        // Who is being made sure of. What the reader asked for names something of this recorder's by its
        // number, and must not go to another that answers in its place.
        let known = session.device
        var stranger = false
        // The packet first and the probe after, as connecting does (`Reach.run`). Not looked for at another
        // address from here: only a connect does that.
        var answeredTheProbe = true
        let outcome = await Reach.run(Reach.Steps(
            sendPacket: { self.sendMagicPacket() },
            probe: {
                do {
                    let answering = try await client.describe(timeout: RecorderClient.probeTimeout)
                    stranger = self.session.recognises(answering) == .another
                    return nil
                } catch {
                    let failure = (error as? any DeviceError)?.failure ?? .unexpected(String(describing: error))
                    if failure == .silent {
                        // Silence, which is what waking is for. Where a connect's first probe leaves things
                        // too, and what waking starts from.
                        answeredTheProbe = false
                        self.session.wentSilent(on: network)
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
            // Another recorder answers where the one in play was -- on the probe, or after a waking, whose
            // attach has turned the app to it already. What the reader asked for names something of the last
            // recorder's by its number, and is not sent.
            if stranger || (known != nil && session.device != known) {
                // Its lists go at once, and the newcomer is taken up by a connect of its own, which reads its
                // reservations and its guide as a waking's attach does not. A job under way was the last
                // recorder's: it is stopped before its next step, and the connect waits for it to end, since
                // one does not start beside a job. What the job came to goes with the lists it was about.
                forgetTheRecorder()
                cancelBulk()
                // Said twice: the failure line for whoever asked, which the connect below takes away, and the
                // strip after that.
                problem = Self.anotherAnswered
                anotherTookOver = true
                let running = jobTask
                Task {
                    await running?.value
                    self.clearJob()
                    await self.connect()
                }
                return false
            }
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

    /// The app has gone to the background, which is what makes coming back worth a reconnect. Only this
    /// counts: Control Centre, the app switcher or a system alert take the app out of `.active` without it
    /// going anywhere, and reconnecting after each sent a magic packet for a glance at the time.
    func wentToBackground() {
        inBackground = true
        // The line about the queue was for this visit. Coming back sends the queue again when there is
        // anything to send, and says what became of that. So was the one about another recorder.
        flushReport = nil
        anotherTookOver = false
    }

    /// The app is active again. The recorder may have gone to sleep meanwhile -- a BDZ-FBT4100 leaves the
    /// network after a quarter of an hour or so -- and connecting again also sends anything queued. Connects
    /// only when the app has really been away (`wentToBackground`).
    func returnedToForeground() async {
        let wasAway = inBackground
        inBackground = false
        // A bulk job waiting between two steps goes on, and makes sure of the recorder itself first.
        backInFront?.resume()
        backInFront = nil
        // Before any of the reasons below not to connect: a day may have gone by while the app was away,
        // with or without a recorder to ask.
        if followTheClock() { await reloadFromCache() }
        // What coming back is worth is `LinkRules.onReturn`'s to say: nothing after a moment in Control
        // Centre; no second client while something is under way or a check is out; not on every flick between
        // apps, since any answer within the last minute counts; and not when this very network was already
        // tried and said nothing -- though the network may be about to change, which the look catches.
        let hasAddress = !host.isEmpty, busyNow = busy != nil, checking = wakeCheck != nil
        // The last answer is on the client's actor, and asking gives up this one's turn: asked only where
        // the rule will read it.
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

    /// The watcher's report, which is news of the network but not yet the network: iOS reports a path as
    /// soon as it can be used, before the phone has its IPv4 address there, and says nothing more when the
    /// address arrives. So the network is looked at again for a while after each report
    /// (`LinkRules.looksAfterAReport`), until something has been done about it. What keeps the app busy for
    /// longer ends in `lostTheRecorder` if the network took the recorder away, which sets the looks going
    /// again.
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
        session.noted(network: surroundings.networkSignature())
    }

    /// The network changed while the app was open: the one thing that makes another attempt worth making
    /// without being asked, and, while connected, the one thing that makes the last answer worth nothing.
    /// The recorder is asked again with the client in hand, as before an operation. Returns whether an
    /// attempt was made, or the recorder made sure of.
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
            let before = session.link.tries
            await connect()
            return session.link.tries != before
        case .makeSure:
            session.tried(on: surroundings.networkSignature())
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
