import Foundation
import Network
import RecorderKit
import SwiftUI

/// Everything the screens share: which recorder we talk to, the guide cache, and what is on screen now.
///
/// There is no server in the middle. The app holds one `RecorderClient`, which serialises its own requests,
/// and one `GuideStore` on disk, so the guide can be read while away from home.
@MainActor
@Observable
final class AppModel {
    /// The recorder's address on the LAN. Discovery by scanning comes later; for now it is typed in.
    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Self.hostKey) }
    }

    var broadcasting = "td"
    var day: Date
    var reservationSort = ReservationSort.time
    var reservationKind = ReservationKind.all
    var titleGenre: Int?
    var titleState: WatchState?
    var titleSort = TitleSort.newest
    var serviceFilter: Int?

    private(set) var info: RecorderDescription?
    private(set) var firmware = ""
    private(set) var storage: (free: Int, total: Int)?
    private(set) var counts: [String: GuideCounts] = [:]
    private(set) var channels: [Channel] = []
    /// Every channel's name and logo, of every broadcasting type, so a reservation or a search result can
    /// say where it comes from.
    private(set) var channelNames: [String: String] = [:]
    private(set) var channelLogos: [String: Data] = [:]
    private(set) var programs: [GuideProgramRow] = []
    private(set) var reservations: [Reservation] = []
    private(set) var titles: [RecordedTitle] = []
    /// Recordings are read in pages of 200 and there are well over a thousand, so they are kept once fetched.
    private(set) var titlesLoaded = false
    /// Reservations by the programme they follow, so the guide can mark what is already set to record.
    private(set) var reservationsByProgram: [String: Reservation] = [:]
    private(set) var found: [RecorderDescription] = []
    private(set) var scanning: (done: Int, total: Int)?
    /// What the last scan came to, said right under the button that started it. Kept apart from `problem`,
    /// which every screen shows as a failure: a scan that found nothing was said at the foot of the
    /// tutorial, below the fold on most iPhones, and after "あとで設定" the guide showed it as an error.
    private(set) var scanOutcome: ScanOutcome?
    /// Set while a scan is held up by local network privacy -- the system's question is on screen, or was
    /// answered no -- so that the screens can say so and offer the Settings app.
    private(set) var scanBlocked = false
    /// Set when the recorder said nothing because local network privacy stopped the app asking. The app
    /// is then waiting for the permission rather than for the recorder; see `watchForAccess`.
    private(set) var connectBlocked = false
    /// Either of the two: something the reader wants is waiting on the local network permission.
    var lanBlocked: Bool { scanBlocked || connectBlocked }
    /// The scan under way, kept so that leaving the tutorial or turning to the demo can stop it -- above all
    /// while it waits on the system's question, which could otherwise outlive the screen that asked.
    private var scanTask: Task<Void, Never>?
    /// Counts scans, so that what an earlier one reports late is not taken for the one running now.
    private var scanRun = 0
    /// Waits for the local network permission after a connect ran into it, and connects when it comes.
    private var accessWatch: Task<Void, Never>?
    /// Everything under way with the recorder, each with a line of its own. Work overlaps -- a tab asking
    /// for its list while another is still loading -- and the client finishes it first come, first served,
    /// so nothing here can save one shared line and put it back afterwards. See `Activities`.
    private var activities = Activities()
    /// What the app is doing with the recorder, for the strip and the screens to say. Nil when nothing is.
    var busy: String? { activities.current }
    /// Set while the app is only waiting for the recorder to come back from a magic packet, or looking for it
    /// at another address after that (`findMovedRecorder`). Nothing is being written and nothing is being
    /// read, so the screens leave alive what they can: a reservation made during these seconds goes to the
    /// queue, which is what the queue is for.
    private(set) var waking = false
    /// Set once the recorder has been given every chance and did not answer. Nothing is asked of it again
    /// until either the network this device is on changes or the reader asks for it, because the answer
    /// will be the same and each ask costs a timeout: the client serialises its requests, so a screen full
    /// of lists wanting to load turns into minutes of a spinner saying the wrong thing.
    private(set) var gaveUp = false
    /// The network we were on when we last tried. A different one is worth another try by itself.
    private var triedOn: String?
    /// Set when the recorder answered that it is in network standby, so the caller can offer to wake it.
    private(set) var needsPower = false
    /// Set when the recorder answered nothing at all rather than answering with an error.
    private(set) var unreachable = false
    private(set) var problem: String?
    /// Set when a reservation went to the queue instead of the recorder, so a screen can say so once.
    var queued: PendingReservation?
    /// The MAC a magic packet is sent to. The recorder reports it whenever it is reached; the reader can
    /// also type it, for a recorder that has never been reached from this phone.
    private(set) var mac: String?

    private var store: GuideStore?
    private var client: RecorderClient?
    /// Opening the cache and reading it, shared by every caller of `start()` and by `connect()`.
    private var opening: Task<Void, Never>?
    /// Set once the first connect has been set going, so that it is set going once, however many screens
    /// call `start()`.
    private var launched = false
    private var pathMonitor: NWPathMonitor?
    /// Kept for as long as the demo lasts, because it holds what the reader has done to it: a reservation
    /// made in the demo has to still be there after a reconnect.
    private var demoRecorder: DemoRecorder?
    /// Two connects at once would mean two clients, two magic packets and two conversations with a recorder
    /// that answers 503 to the second. The network monitor can fire at any moment, so this is not academic.
    private var connecting = false
    /// Set when the app went to the background, and cleared when it is back in front. See `wentToBackground`.
    private var inBackground = false
    /// A bulk job waiting between two steps for the app to come back. See `readyForNextStep`.
    private var backInFront: CheckedContinuation<Void, Never>?
    /// The background task the step of a bulk job under way runs under. See `keepingAlive`.
    private var stepTask = UIBackgroundTaskIdentifier.invalid

    private static let hostKey = "recorderHost"
    private static let macKey = "recorderMac"
    /// The address the recorder was at when it reported the MAC. See `macWasReadHere`.
    private static let macHostKey = "recorderMacHost"

    init() {
        demo = DemoData.on
        let days = GuideStore.broadcastDays()
        self.days = days
        host = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
        mac = UserDefaults.standard.string(forKey: Self.macKey)
        // Here rather than in `start()`: the first screen decides whether to show the tutorial by looking at
        // whether a recorder is set, and it looks before `start()` has run.
        if DemoData.on { host = DemoData.host; mac = DemoData.mac }
        day = days.first ?? Date()
    }

    var connected: Bool { info != nil }

    /// True while the app is showing the invented recorder rather than a real one. Every screen says so, and
    /// the demo writes its guide to a database of its own, so nothing of it is left behind afterwards.
    ///
    /// A copy of `DemoData.on` rather than a read of it: that lives in UserDefaults, where no screen sees it
    /// change, and ending the demo left the strip saying the data was invented -- with a 終了 that did
    /// nothing -- until something else on the model happened to move.
    private(set) var demo: Bool

    /// True while something is going on that a second request would only get in the way of. Waking is not
    /// one of them, on purpose -- see `waking`.
    var working: Bool { busy != nil && !waking }

    /// True while there is no point asking the recorder anything: either nothing has been set up, or the
    /// last ask got silence. Every list guards on it, so that going out of range costs one timeout rather
    /// than one per screen.
    var offline: Bool { client == nil || unreachable }

    /// Whether this device is on a different network from the one the last attempt was made on.
    var networkChanged: Bool { LocalNetwork.signature() != triedOn }

    /// Bumped when the reader asks to be taken back to what is on now. A count rather than a flag, so that
    /// asking twice works.
    private(set) var nowRequests = 0

    /// Today, at this minute. Tapping the guide tab while already on it scrolls to the top of the day by
    /// itself, and the top of a broadcast day is four in the morning, which is nobody's idea of home.
    ///
    /// The programmes are read again when that changed the day. Moving the day alone put today's date over
    /// whichever day had been open, and the grid, finding none of it on today, came up empty. The ask to
    /// go to now waits for them, so that it is answered from the day it names.
    func goToNow() {
        let before = day
        followTheClock()
        day = days.first ?? Date()
        guard day != before else {
            nowRequests += 1
            return
        }
        Task {
            await reloadFromCache()
            nowRequests += 1
        }
    }

    /// Moves the day strip on when the broadcast day on air is no longer its first. A process the system
    /// kept alive overnight comes back to the days it worked out the evening before: it opened on
    /// yesterday, going back to now went to yesterday, and the eighth day was out of reach. The day on screen
    /// stays if it is still in the strip -- tomorrow, looked at last night, is today now -- and otherwise
    /// goes to the first.
    ///
    /// Asked wherever the reader arrives -- the app starting, coming back to it, going back to now -- because
    /// nothing says when four in the morning has passed: `significantTimeChangeNotification` comes at
    /// midnight.
    ///
    /// Returns whether `day` moved, since the programmes on screen are then those of a day no longer shown.
    @discardableResult
    private func followTheClock() -> Bool {
        let current = GuideStore.broadcastDays()
        guard current.first != days.first else { return false }
        days = current
        guard !days.contains(day) else { return false }
        day = days.first ?? day
        return true
    }

    /// Opens the cache and shows what is in it. Every screen awaits this before asking for anything, and
    /// only the first caller does the work.
    ///
    /// The first call also sets the first connect going, without waiting for it. Waiting was a deadlock:
    /// the connect ran inside the task this awaited, and reading the reservations -- which the connect does
    /// -- awaited this, so the connect waited for itself and the app spun until it was quit. Only a race
    /// with coming to the foreground, which usually got its own connect in first, kept it from being seen.
    /// So nothing `connect()` reaches may await this; it uses the `...Now` loads, which do not. Not waiting
    /// also lets a search, which needs nothing but the cache, answer at once rather than after half a
    /// minute of waking a recorder that is not there.
    func start() async {
        // The days were worked out when the model was made, and a process the system started in the night
        // for the overnight run is still here when the app is opened in the morning.
        let moved = followTheClock()
        await openCache()
        if moved { await reloadFromCache() }
        guard !launched, store != nil else { return }
        launched = true
        Task { await self.connectFirstTime() }
    }

    /// Shows the cached guide before touching the network, so something is on screen at once. Safe to
    /// await from anywhere, `connect()` included, because nothing in it goes near the recorder.
    private func openCache() async {
        if opening == nil { opening = Task { await self.readCache() } }
        await opening?.value
    }

    private func readCache() async {
        guard store == nil else { return }
        do {
            store = try GuideStore(path: try Storage.guidePath())
            // Invented programmes: for the screenshots, and for anyone without a recorder to hand. See
            // DemoData.
            if DemoData.on, let store { try? await DemoData.seed(store: store) }
            await reloadFromCache()
        } catch {
            problem = "番組表の保存領域を開けませんでした: \(error)"
        }
    }

    private func connectFirstTime() async {
        if !host.isEmpty { await connect() }
        // After the first attempt, not before it: `NWPathMonitor` reports the path it already has as
        // soon as it starts, and that would be a second connect racing the first.
        watchNetwork()
    }

    /// Asks again when the network underneath changes, and only then. `NWPathMonitor` reports rather more
    /// than that -- an interface going up on its own account, a route changing -- so the decision is left to
    /// the addresses this device holds, which is what actually says whether the recorder might be nearby.
    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { _ in
            Task { @MainActor [weak self] in await self?.networkChangedWhileOpen() }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    // MARK: - the demo

    /// Shows the invented recorder. Offered in the tutorial, because the first thing the app asks for is a
    /// recorder on the network, and not everyone has one to hand when they are deciding whether this is
    /// worth setting up -- the reviewer who has to judge it least of all.
    func enterDemo() async {
        guard !demo else { return }
        // A scan still waiting on the local network question has nothing to do with the invented recorder,
        // and the demo is exactly the path that must never raise that question.
        stopScanning()
        DemoData.turnOn(realHost: host, realMac: mac)
        demo = true
        await openStore()
        host = DemoData.host
        remember(mac: DemoData.mac)
        await connect()
    }

    /// Puts back whatever was there before, and takes the demo's guide with it: the invented programmes live
    /// in their own database, which is deleted here rather than left to be mistaken for a real one.
    func leaveDemo() async {
        guard demo else { return }
        let before = DemoData.turnOff()
        demo = false
        demoRecorder = nil
        Storage.removeDemoGuide()
        host = before.host
        if let mac = before.mac { remember(mac: mac) } else { forgetMac() }
        await openStore()
        if !host.isEmpty { await connect() }
    }

    /// Opens the cache that belongs to whichever recorder is in play now, and forgets everything the other
    /// one said.
    private func openStore() async {
        info = nil
        firmware = ""
        storage = nil
        client = nil
        reservations = []
        reservationsByProgram = [:]
        titles = []
        titlesLoaded = false
        recorderRules = []
        pending = []
        duplicates = []
        duplicatePicks = []
        unreadDuplicates = 0
        summaries = [:]
        problem = nil
        unreachable = false
        gaveUp = false
        found = []
        scanOutcome = nil
        accessWatch?.cancel()
        accessWatch = nil
        connectBlocked = false
        store = (try? Storage.guidePath()).flatMap { try? GuideStore(path: $0) }
        if let store {
            if demo { try? await DemoData.seed(store: store) }
            await reloadFromCache()
            await loadPending()
        }
    }

    /// Looks through the subnet this device is on for a recorder, as a task of its own that `stopScanning`
    /// can end. One short request per address, and the first time, iOS asks the reader whether the app may
    /// reach the local network.
    ///
    /// The scan waits for that answer before it starts. It used to go straight ahead behind the question,
    /// where every request failed at once and the scan came back with nothing; the reader allowed it and had
    /// to tap a second time, under a red line saying no recorder had been found.
    func scanForRecorders() {
        scanTask?.cancel()
        scanTask = Task { await scan() }
    }

    /// Ends a scan wherever it has got to, the wait for the permission included.
    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
        scanRun += 1
        scanning = nil
        scanBlocked = false
    }

    private func scan() async {
        scanRun += 1
        let run = scanRun
        // whatever the last attempt left on screen is not about this one
        problem = nil
        scanOutcome = nil
        found = []
        let lan = LocalNetwork.lanInterfaces()
        let hosts = lan.flatMap { LocalNetwork.hosts(around: $0) }
        guard let neighbour = lan.lazy.compactMap(LocalNetwork.neighbour(on:)).first, !hosts.isEmpty else {
            report(.noWiFi)
            return
        }
        scanning = (0, hosts.count)
        let allowed = await LocalNetwork.waitForAccess(probing: neighbour) { @MainActor [weak self] in
            guard let self, self.scanRun == run else { return }
            self.scanBlocked = true
        }
        guard scanRun == run, !Task.isCancelled else { return }
        scanBlocked = false
        // Neither allowed nor refused: the path went for some other reason while waiting, most likely the
        // Wi-Fi itself. When it has, say that, rather than scan nothing and report nothing found.
        if !allowed, LocalNetwork.lanInterfaces().isEmpty {
            scanning = nil
            report(.noWiFi)
            return
        }
        // a recorder shows up the moment it answers, so the reader can take it while the rest of the
        // subnet is still being tried
        let result = await Discovery.scan(hosts: hosts, progress: { done, total in
            Task { @MainActor in
                guard self.scanRun == run, self.scanning != nil else { return }
                self.scanning = (done, total)
            }
        }, found: { recorder in
            Task { @MainActor in
                guard self.scanRun == run else { return }
                if !self.found.contains(where: { $0.host == recorder.host }) { self.found.append(recorder) }
            }
        })
        guard scanRun == run, !Task.isCancelled else { return }
        found = result
        scanning = nil
        scanTask = nil
        report(result.isEmpty ? .nothing : .found(result.count))
    }

    /// Puts the outcome under the button, and says it aloud as well: the words appear below where a
    /// VoiceOver reader's focus still is, on the button they tapped.
    private func report(_ outcome: ScanOutcome) {
        scanOutcome = outcome
        AccessibilityNotification.Announcement(outcome.text).post()
    }

    enum ScanOutcome: Equatable {
        case found(Int)
        case nothing
        case noWiFi

        var text: String {
            switch self {
            case .found(let count): "レコーダーが \(count) 台見つかりました"
            case .nothing: "レコーダーが見つかりませんでした。レコーダーの電源が入っていて、"
                + "iPhone と同じ Wi-Fi につながっているか確認してください。"
            case .noWiFi: "Wi-Fi に接続されていません。レコーダーと同じ Wi-Fi につないでから、もう一度お試しください。"
            }
        }

        var failed: Bool {
            if case .found = self { return false }
            return true
        }
    }

    /// Takes one of the recorders the scan turned up.
    func use(_ recorder: RecorderDescription) async {
        // The reader has chosen, so the rest of the subnet no longer matters -- and a scan left running would
        // put the list back when it finished.
        stopScanning()
        scanOutcome = nil
        host = recorder.host
        found = []
        await connect()
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
        let client: RecorderClient
        if DemoData.on {
            let recorder = demoRecorder ?? DemoRecorder()
            demoRecorder = recorder
            client = RecorderClient(host: host, transport: recorder)
        } else {
            client = RecorderClient(host: host)
        }
        self.client = client
        // The first ask is a short one. A recorder that has left the network does not refuse the
        // connection, it says nothing, so a patient timeout means half a minute of silence before anything
        // can be done about it — and that silence looked like the waking never happened.
        // The packet is a hundred bytes and the probe takes five seconds to fail, so send it now rather
        // than after: a recorder that is asleep is already on its way up while the first probe runs, and one
        // that is awake ignores it. Waiting for the failure first is what made this look like a fault
        // followed by a retry.
        sendMagicPacket()
        triedOn = LocalNetwork.signature()
        var reached = await attach(client, timeout: RecorderClient.probeTimeout, quiet: canWake)
        if !reached, unreachable, !demo, await lanIsBlocked() {
            waitForPermission()
            return
        }
        connectBlocked = false
        if !reached { reached = await wakeAndAttach(client) }
        // Not back where it was after the waking: it may be answering at another address. One look, here and
        // nowhere else, so the rule below about not trying again stands.
        if !reached, unreachable, let moved = await findMovedRecorder() {
            host = moved.host
            // It is the recorder the MAC was read from, which its UDN has just said.
            UserDefaults.standard.set(moved.host, forKey: Self.macHostKey)
            let found = RecorderClient(host: moved.host)
            self.client = found
            reached = await attach(found, timeout: RecorderClient.probeTimeout)
        }
        // Trying again by itself would only spend another half-minute arriving at the same silence. The
        // reader has "再接続" and "レコーダーを探す" for when they know something has changed, and a change of
        // network asks again without being told to.
        // Only silence, though. A recorder that answered, if only to refuse -- a 503 because something else
        // was talking to it, a fault from a model without one of the calls -- is there, and has said what is
        // wrong already. Giving up on it put "not connected" on screen beside a recorder that was answering,
        // and kept the next return to the app from asking again.
        gaveUp = !reached && unreachable
        if reached {
            // Before the guide, because the guide marks what is already set to record and the marks come
            // from this list. Reading it only when the reservations screen appeared meant that opening the
            // app on the guide -- which is where it opens -- showed a programme as unreserved until you had
            // been to the other tab and back.
            await loadReservationsNow()
            await refreshGuideIfStale()
        }
    }

    /// Whether local network privacy is why the recorder said nothing. Aimed at the recorder's own address,
    /// because that is the connection the permission would have stopped. At most two seconds; the path
    /// answers at once in practice. Only asked in the foreground, after a real recorder was silent -- never
    /// by the overnight run, which has no screen to explain it on, and never in the demo, which has to go
    /// through without the system's question ever coming up.
    private func lanIsBlocked() async -> Bool {
        await LocalNetwork.access(probing: host) == .blocked
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
            UserDefaults.standard.set(host, forKey: Self.hostKey)
            firmware = try await client.firmwareVersion()
            // Kept for waking it later. The recorder is the only place this can come from on iOS, which
            // cannot read an ARP table, so it is read every time rather than once. With the address it was
            // read at, which is what lets the recorder be recognised by it somewhere else: see
            // `findMovedRecorder`. Not the demo's, which is at an address that is nobody's.
            if let settings = try? await client.networkSettings(), remember(mac: settings.mac), !demo {
                UserDefaults.standard.set(host, forKey: Self.macHostKey)
            }
            let capacity = try await client.recordDestinationInfo()
            storage = (capacity.freeBytes, capacity.totalBytes)
            unreachable = false
            problem = nil
            await flushPending()
            // The recorder can go quiet in the middle of sending the queue, which leaves the app offline
            // like any other silence; a connect that ended there has not reached anything to show.
            return !unreachable
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

    /// The magic packet, then waiting for the recorder to answer. Nothing acknowledges the packet, so the
    /// only way to know is to keep asking; a BDZ-FBT4100 is back in about ten seconds.
    /// Sends the packet, if there is a MAC to send it to. Nothing acknowledges it, so nothing is returned.
    private func sendMagicPacket() {
        if DemoData.on { return }   // nothing to wake, and no reason to shout on somebody's LAN
        guard let mac else { return }
        _ = WakeOnLan.wake(mac, addresses: WakeOnLan.addresses(forRecorderAt: host))
    }

    @discardableResult
    func wakeAndAttach(_ client: RecorderClient? = nil) async -> Bool {
        guard let client = client ?? self.client, unreachable, mac != nil else { return false }
        sendMagicPacket()   // again: connect() sends one too, and a second costs nothing
        // Nothing is wrong yet, so nothing should be on screen saying there is. The probe that got us here
        // was quiet for the same reason, and each attempt below is too: waking takes a few tries, and a
        // failure line appearing and vanishing between them says the wrong thing.
        problem = nil
        waking = true
        let started = Date()
        let activity = activities.begin(Self.wakingLine(0))
        defer { waking = false; activities.end(activity) }
        // A BDZ-FBT4100 takes six to eleven seconds to answer after the packet, so half a minute is
        // generous. Bounded by the clock rather than by a count of attempts, so that the line on screen and
        // the wait behind it are the same length -- and the line says how long it has been, because a
        // spinner that has been going for twenty seconds is otherwise indistinguishable from a hung one.
        while Date().timeIntervalSince(started) < Self.wakeLimit {
            activities.update(activity, to: Self.wakingLine(Int(Date().timeIntervalSince(started))))
            // Only the identity, and only for two seconds: asking for everything is what the attach below
            // is for, and it is worth doing once, after the recorder has proved it is listening.
            if (try? await client.describe(timeout: RecorderClient.wakeProbeTimeout)) != nil {
                return await attach(client, what: "接続中", timeout: RecorderClient.probeTimeout)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        problem = "レコーダーが応答しません。電源とネットワーク接続を確認してください。"
        return false
    }

    /// How long to wait for a recorder to come back from a magic packet before leaving it alone.
    private static let wakeLimit: TimeInterval = 30

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
        guard !demo, !inBackground, let mac, macWasReadHere else { return nil }
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
        guard let readAt = UserDefaults.standard.string(forKey: Self.macHostKey) else { return true }
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
    private func lostTheRecorder() {
        unreachable = true
        info = nil
        gaveUp = true
        triedOn = LocalNetwork.signature()
    }

    /// Said when a write met silence. Whether it arrived is not known, which is exactly why it is not sent
    /// again, and what the list says once the recorder answers is the only way to find out.
    private static let mayHaveArrived = "送信の途中でレコーダーの応答がなくなりました。届いている場合もあるため、"
        + "送り直していません。再接続してから一覧で確かめてください。"

    /// Why something the reader asked for was not sent at all: the app is not connected.
    private var notConnected: String {
        connectBlocked ? LocalNetworkNotice.title
            : "レコーダーに接続していません。「再接続」を押してから、もう一度お試しください。"
    }

    /// How long the recorder may say nothing before it is worth making sure it is still up, ahead of something
    /// the reader asked for. A BDZ-FBT4100 leaves the network after a quarter of an hour or so with nothing
    /// asked of it, and has been seen awake for as little as two minutes at a time; a minute and a half is
    /// well inside both, and a recorder that is up answers the check in milliseconds.
    private static let dozeAfter: TimeInterval = 90

    /// The check under way, so that everything asked for while it runs waits for its answer rather than
    /// sending a probe -- and a magic packet -- of its own.
    private var wakeCheck: Task<Bool, Never>?

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
    private func wakeIfDozing(evenIfRecent: Bool = false) async -> Bool {
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
        if !evenIfRecent, let last = await client.lastAnswer, Date().timeIntervalSince(last) < Self.dozeAfter {
            return true
        }
        // The packet first and the probe after, as connecting does: a recorder that is asleep is on its way
        // up while the probe waits, and one that is awake ignores it.
        sendMagicPacket()
        do {
            try await client.describe(timeout: RecorderClient.probeTimeout)
            return true
        } catch let error as RecorderError where error.unreachable {
            // silence, which is what waking is for
        } catch {
            // Something answered, so there is nothing to wake. What is wrong is for the request itself to
            // run into and say.
            return true
        }
        // Where a connect's first probe leaves things too, and what waking starts from.
        unreachable = true
        info = nil
        triedOn = LocalNetwork.signature()
        if !demo, await lanIsBlocked() {
            waitForPermission()
            return false
        }
        if await wakeAndAttach(client) { return true }
        // Given up, as a connect is when waking does not bring the recorder back. Something that answered
        // only to refuse has said so already, and is not silence, so it is not given up on either: see
        // `connect()`.
        guard unreachable else { return false }
        lostTheRecorder()
        // Waking says why it gave up; without a MAC there was no waking to say it.
        if !canWake { problem = RecorderError.transport("no answer").explanation }
        return false
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
        UserDefaults.standard.set(normalised, forKey: Self.macKey)
        return true
    }

    func forgetMac() {
        mac = nil
        UserDefaults.standard.removeObject(forKey: Self.macKey)
        UserDefaults.standard.removeObject(forKey: Self.macHostKey)
    }

    /// The recorder builds its guide files again in the small hours, so a cache from before the most recent
    /// rebuild is behind what the recorder would hand over now.
    static func lastRebuild(before now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let previous = calendar.nextDate(after: now, matching: DateComponents(hour: 1, minute: 0),
                                         matchingPolicy: .nextTime, direction: .backward)
        return previous ?? now.addingTimeInterval(-24 * 3600)
    }

    /// Whether the cache holds nothing, or nothing newer than that rebuild.
    var guideIsStale: Bool {
        guard counts.values.contains(where: { $0.programs > 0 }),
              let newest = counts.values.compactMap(\.refreshed).compactMap(RecorderTime.parse).max()
        else { return true }
        return newest < Self.lastRebuild()
    }

    /// Fetching the guide is what connecting is for, so it happens without being asked: the first run
    /// otherwise lands on an empty guide with nothing to say that anything has to be fetched, and a cache
    /// the overnight run never got to would quietly stay a day behind. A cache that is already current
    /// costs nothing, which is what makes this safe on every launch.
    func refreshGuideIfStale() async {
        guard connected else { return }
        // Judged by what the cache holds now, not by what this model read from it last. The overnight run
        // writes the cache without going through the model -- in this very process, when the app was kept
        // alive behind it -- and deciding on the counts from the evening before fetched every broadcasting
        // type again each morning. What it wrote goes on screen as well.
        if let store, let cached = try? await store.counts(), cached != counts { await reloadFromCache() }
        guard guideIsStale else { return }
        await refreshGuide()
    }

    /// Downloads every broadcasting type the recorder has and replaces the cache.
    func refreshGuide() async {
        guard let client, let store, !unreachable else { return }
        await run("番組表を取得中") { activity in
            try await GuideRefresh.run(client: client, store: store) { broadcasting in
                let label = Codes.broadcastingLabel[broadcasting] ?? broadcasting
                self.activities.update(activity, to: "番組表を取得中 (\(label))")
            }
            await self.reloadFromCache()
        }
    }

    func loadReservations() async {
        await start()
        await loadReservationsNow()
    }

    /// The load itself, for `connect()` and everything it reaches, which must not await `start()`: see there.
    private func loadReservationsNow() async {
        guard let client, !unreachable else { return }
        await run("予約一覧を取得中") {
            self.reservations = try await client.reservations()
            self.reservationsByProgram = Dictionary(
                self.reservations.compactMap { reservation in
                    reservation.eventID.map { (Self.key(reservation.broadcastingType, reservation.serviceID, $0),
                                               reservation) }
                },
                uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - the recorder's own keyword conditions (おまかせ・まる録)

    private(set) var recorderRules: [RecorderRule] = []

    /// Reservations made while the recorder could not be reached, waiting for it to answer.
    private(set) var pending: [PendingReservation] = []

    func loadRecorderRules() async {
        await start()
        guard let client, !unreachable else { return }
        await run("おまかせ・まる録の設定を取得中") { self.recorderRules = try await client.recorderRules() }
    }

    /// Registers a condition on the recorder itself, which then records by it with nothing else running.
    func addRecorderRule(_ request: RecorderRuleRequest) async -> Bool {
        await start()
        guard let client else { return false }
        let made = await run("レコーダーに登録中", sending: true) {
            _ = try await client.createRecorderRule(request)
        }
        if made { await loadRecorderRules() }
        return made
    }

    /// Delete only, never edit: a condition read over the LAN lacks the channel narrowing the recorder's own
    /// screen can set, and writing it back would erase that. The list is read again afterwards either way,
    /// because the recorder renumbers a condition whenever its screen edits one.
    func removeRecorderRule(_ rule: RecorderRule) async -> Bool {
        await start()
        guard let client else { return false }
        let removed = await run("レコーダーから削除中", sending: true) {
            try await client.deleteRecorderRule(id: rule.id)
        }
        await loadRecorderRules()
        return removed
    }

    // MARK: - bulk work

    /// Deleting or protecting many recordings, one request at a time because that is all the recorder will
    /// take. It lives here rather than in a screen so that closing the sheet that started it neither stops it
    /// nor takes away the way to stop it.
    struct BulkJob: Equatable {
        enum Kind: Equatable {
            case delete
            case protecting(Bool)
            /// Asking the recorder what each candidate is about. It changes nothing.
            case scanning
        }

        struct Skip: Equatable, Identifiable {
            var id: String
            var reason: String
        }

        var kind: Kind
        var total: Int
        var done = 0
        var changed: [String] = []
        var skipped: [Skip] = []
        var cancelled = false
        /// Set when the recorder stopped answering and the job stopped there.
        var lostRecorder = false
        var finished = false

        var verb: String {
            switch kind {
            case .delete: "削除"
            case .protecting(true): "保護"
            case .protecting(false): "保護解除"
            case .scanning: "重複の検出"
            }
        }

        var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

        /// What to tell the reader once it has stopped, in the shape the web app settled on.
        var outcome: String {
            if case .scanning = kind {
                let head = lostRecorder ? "\(done) 件まで調べたところで、レコーダーの応答がなくなったため中止しました"
                    : cancelled ? "\(done) 件まで調べて中止しました" : "\(done) 件の確認が完了しました"
                return skipped.isEmpty ? head : head + "（\(skipped.count) 件は番組内容を取得できず、比べていません）"
            }
            let count = changed.count
            let head = lostRecorder ? "\(count) 件を\(verb)したところで、レコーダーの応答がなくなったため中止しました"
                : cancelled ? "\(count) 件を\(verb)したところで中止しました" : "\(count) 件を\(verb)しました"
            return skipped.isEmpty ? head : head + "（\(skipped.count) 件はスキップ）"
        }
    }

    private(set) var job: BulkJob?
    private(set) var duplicates: [DuplicateSet] = []
    /// Which copies are ticked for deletion; the ones left unticked are kept. It lives here because the view
    /// holding it is thrown away every time the reader looks at the list or the programmes instead.
    var duplicatePicks: Set<String> = []
    /// How many candidates were left out of the sets because their text has not been read, which a scan run
    /// again reads.
    private(set) var unreadDuplicates = 0
    /// What the recorder said each recording is about, cached on disk as well. Only what it actually said:
    /// a recording missing here has not been read.
    private var summaries: [String: String] = [:]
    private var jobTask: Task<Void, Never>?

    var jobRunning: Bool { job.map { !$0.finished } ?? false }

    func startBulk(_ kind: BulkJob.Kind, ids: [String]) {
        guard jobTask == nil, !ids.isEmpty, let client else { return }
        job = BulkJob(kind: kind, total: ids.count)
        jobTask = Task { [weak self] in
            await self?.runBulk(kind, ids: ids, client: client)
        }
    }

    /// Stops before the next recording. What has been done stays done; the recorder has no undo.
    func cancelBulk() {
        job?.cancelled = true
    }

    func clearJob() {
        guard job?.finished == true else { return }
        job = nil
    }

    private func runBulk(_ kind: BulkJob.Kind, ids: [String], client: RecorderClient) async {
        // Made sure of first, like anything else the reader asks for: a recorder asleep since the list was
        // read would otherwise cost the first recording a timeout, and every one after it another.
        if await wakeIfDozing() {
            for id in ids {
                guard await readyForNextStep() else {
                    job?.lostRecorder = true
                    break
                }
                // after the wait, so that 中止 tapped while the recorder was being woken is heeded
                if job?.cancelled == true { break }
                do {
                    try await keepingAlive {
                        switch kind {
                        case .delete: try await deleteOne(id, client)
                        case .protecting(let on): try await protectOne(id, on, client)
                        case .scanning: break
                        }
                    }
                } catch {
                    // Silence. Stop at the first, since every recording after it would wait out the same
                    // timeout, and do not send this one again: it may have gone through. The list is read
                    // again once the recorder answers, which settles what became of it.
                    lostTheRecorder()
                    titlesLoaded = false
                    job?.lostRecorder = true
                    break
                }
                job?.done += 1
            }
        } else {
            job?.lostRecorder = true
        }
        if case .delete = kind, !unreachable, let capacity = try? await client.recordDestinationInfo() {
            storage = (capacity.freeBytes, capacity.totalBytes)
        }
        // the sets were built from recordings that may no longer all be there
        if !duplicates.isEmpty { recomputeDuplicates() }
        job?.finished = true
        jobTask = nil
    }

    /// Whether a bulk job or the scan may take its next step, having waited first for as long as the app is
    /// in the background.
    ///
    /// No step is started while the reader is away. iOS suspends the app soon after it leaves, and a request
    /// frozen with it comes back as a failure, which would stop the job for a recorder that had gone nowhere,
    /// unsure whether the recording it was on had been deleted. So the job waits here, between two steps, and
    /// goes on when the app is back -- after making sure of a recorder that has had all that time to fall
    /// asleep. The step under way as the reader leaves is finished first, under `keepingAlive`.
    ///
    /// False when the recorder is not there to ask. Silence met by anything stops the job, not only silence
    /// met by the job: a list another screen was loading may have met it first, and the next step would only
    /// wait out the same timeout to find out again.
    private func readyForNextStep() async -> Bool {
        if inBackground {
            await withCheckedContinuation { backInFront = $0 }
            // A screen coming back may be waking the recorder already, and until that is over the app counts
            // it as not answering. Its outcome is the one to go by.
            if let wakeCheck { _ = await wakeCheck.value }
            guard await wakeIfDozing() else { return false }
        }
        return !unreachable
    }

    /// Runs one step of a bulk job under a background task, so that a step under way when the reader leaves
    /// the app is finished rather than frozen half way (see `readyForNextStep`). iOS allows half a minute or
    /// so, which a step fits in with room to spare unless the recorder has gone quiet, and then the task is
    /// ended when the time runs out, as iOS requires.
    private func keepingAlive<T>(_ step: () async throws -> T) async rethrows -> T {
        stepTask = UIApplication.shared.beginBackgroundTask(withName: "BulkStep") { [weak self] in
            self?.endStepTask()
        }
        defer { endStepTask() }
        return try await step()
    }

    private func endStepTask() {
        guard stepTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(stepTask)
        stepTask = .invalid
    }

    // MARK: - duplicates

    /// Candidates cost nothing to find; confirming them means asking the recorder about each one, which is
    /// why this is a job with a progress bar and a stop button.
    ///
    /// The sets already on screen stay there while it runs, so that one it finds again keeps the ticks the
    /// reader gave it. Ticking waits until it has finished.
    func startDuplicateScan() {
        guard jobTask == nil, let client, let store else { return }
        let candidates = Duplicates.candidates(titles)
        job = BulkJob(kind: .scanning, total: candidates.reduce(0) { $0 + $1.count })
        jobTask = Task { [weak self] in
            await self?.runScan(candidates, client: client, store: store)
        }
    }

    private func runScan(_ candidates: [[RecordedTitle]], client: RecorderClient, store: GuideStore) async {
        let ids = candidates.flatMap { $0.map(\.id) }
        if let known = try? await store.titleSummaries(ids) {
            summaries.merge(known) { _, new in new }
        }
        // The recorder is needed only for what the cache does not already hold, and made sure of only then.
        var answering = true
        if ids.contains(where: { summaries[$0] == nil }) { answering = await wakeIfDozing() }

        scan: for group in candidates {
            for title in group {
                if !answering || job?.cancelled == true { break scan }
                if summaries[title.id] == nil {
                    guard await readyForNextStep() else {
                        answering = false
                        break scan
                    }
                    let read: SummaryRead
                    do {
                        read = try await keepingAlive { try await client.summary(of: title.id) }
                    } catch let error as RecorderError where error.unreachable {
                        // Stop at the first silence rather than wait it out once for every recording left,
                        // and keep nothing for this one: silence says nothing about what it is.
                        lostTheRecorder()
                        answering = false
                        break scan
                    } catch {
                        read = .failed(reason: String(describing: error))
                    }
                    switch read {
                    case .read(let summary):
                        summaries[title.id] = summary
                        try? await store.setTitleSummary(title.id, summary)
                    case .gone:
                        // deleted on the recorder since the list was read, so it is not a copy of anything
                        titles.removeAll { $0.id == title.id }
                    case .failed(let reason):
                        // Nothing is kept, so it is left out of the sets and asked about again next time.
                        job?.skipped.append(.init(id: title.id, reason: reason))
                    }
                }
                job?.done += 1
            }
        }
        if !answering { job?.lostRecorder = true }
        // from the list as it is now, which a recording deleted meanwhile has left
        recomputeDuplicates()
        job?.finished = true
        jobTask = nil
    }

    /// Rebuilds the sets from what is still on the recorder, using the text already gathered.
    ///
    /// A recording whose text has not been read -- the scan was stopped before it, the recorder could not
    /// give it, or it was recorded since -- is left out rather than compared on nothing. With no text, two of
    /// them would agree on their title and length alone, and one would come up ticked for deletion. This is
    /// done here rather than in `Duplicates.sets`, which treats a missing text as an empty one, as the server
    /// that its vectors come from does.
    func recomputeDuplicates() {
        let candidates = Duplicates.candidates(titles)
        let read = candidates.map { $0.filter { summaries[$0.id] != nil } }
        unreadDuplicates = candidates.reduce(0) { $0 + $1.count } - read.reduce(0) { $0 + $1.count }
        setDuplicates(Duplicates.sets(candidates: read, summaries: summaries))
    }

    /// A set the reader has already seen keeps its ticks; a new or changed one is ticked as suggested, if its
    /// text confirms it. See `Duplicates.picks`.
    private func setDuplicates(_ sets: [DuplicateSet]) {
        duplicatePicks = Duplicates.picks(for: sets, shown: duplicates, picked: duplicatePicks)
        duplicates = sets
    }

    /// Throws only silence, which ends the job: see `runBulk`.
    private func deleteOne(_ id: String, _ client: RecorderClient) async throws {
        guard let title = titles.first(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: "一覧に見つかりません"))
            return
        }
        let outcome = try await client.deleteIfPresent(title)
        switch outcome {
        case .changed:
            titles.removeAll { $0.id == id }
            job?.changed.append(id)
        case .skipped(let reason):
            // the recorder had already lost it, so the list should not keep showing it either
            if reason == "すでに削除されています" { titles.removeAll { $0.id == id } }
            job?.skipped.append(.init(id: id, reason: reason))
        }
    }

    private func protectOne(_ id: String, _ on: Bool, _ client: RecorderClient) async throws {
        guard let index = titles.firstIndex(where: { $0.id == id }) else {
            job?.skipped.append(.init(id: id, reason: "一覧に見つかりません"))
            return
        }
        switch try await client.setProtected(titles[index], on) {
        case .changed:
            titles[index].protected = on
            job?.changed.append(id)
        case .skipped(let reason):
            job?.skipped.append(.init(id: id, reason: reason))
        }
    }

    // MARK: - recordings

    enum TitleSort: String, CaseIterable {
        case newest, oldest, largest

        var label: String {
            switch self {
            case .newest: "新しい順"
            case .oldest: "古い順"
            case .largest: "大きい順"
            }
        }
    }

    func loadTitles(force: Bool = false) async {
        await start()
        await loadTitlesNow(force: force)
    }

    /// The load itself, without `start()`, for anything `connect()` reaches: see there.
    private func loadTitlesNow(force: Bool) async {
        guard let client, !unreachable, force || !titlesLoaded else { return }
        await run("録画一覧を取得中") {
            self.titles = try await client.allTitles()
            self.titlesLoaded = true
            // The sets on screen were built from the list as it was. A copy one says it keeps may have gone
            // since, and deleting the others would then leave nothing.
            if !self.duplicates.isEmpty { self.recomputeDuplicates() }
            let capacity = try await client.recordDestinationInfo()
            self.storage = (capacity.freeBytes, capacity.totalBytes)
        }
    }

    /// The recordings the screen is showing: filtered, then sorted.
    var shownTitles: [RecordedTitle] {
        var shown = titles
        if let titleGenre { shown = shown.filter { $0.genre?.level1 == titleGenre } }
        if let titleState { shown = shown.filter { $0.watchState == titleState } }
        switch titleSort {
        case .newest: shown.sort { $0.start > $1.start }
        case .oldest: shown.sort { $0.start < $1.start }
        case .largest: shown.sort { ($0.sizeMB ?? 0) > ($1.sizeMB ?? 0) }
        }
        return shown
    }

    var titleGroups: [TitleGroup] { TitleGroup.group(shownTitles) }

    /// How many recordings each genre holds, for the filter row.
    var titleGenreCounts: [Int: Int] {
        Dictionary(titles.compactMap { $0.genre?.level1 }.map { ($0, 1) }, uniquingKeysWith: +)
    }

    func members(of group: TitleGroup) -> [RecordedTitle] {
        shownTitles.filter { $0.seriesKey == group.key }
    }

    func channelName(for title: RecordedTitle) -> String {
        channelNames["\(title.broadcastingType)-\(title.serviceID)"]
            ?? Codes.broadcastingLabel[Codes.broadcasting(code: title.broadcastingType) ?? ""]
            ?? ""
    }

    /// Asked as a recording's sheet opens, which is also the moment to wake a recorder that has gone to
    /// sleep: what the reader opened it for -- playing, protecting, deleting -- then goes straight through.
    func detail(of title: RecordedTitle) async -> (summary: String, details: [String])? {
        await start()
        guard let client, !unreachable, await wakeIfDozing() else { return nil }
        do {
            return try await client.titleDetail(id: title.id)
        } catch let error as RecorderError where error.unreachable {
            lostTheRecorder()
            return nil
        } catch {
            return nil
        }
    }

    /// A write: the recorder stops deleting this one to make room.
    @discardableResult
    func setProtected(_ title: RecordedTitle, _ on: Bool) async -> Bool {
        await start()
        guard let client else { return false }
        let done = await run(on ? "保護中" : "保護を解除中", sending: true) {
            try await client.updateTitle(id: title.id, protected: on)
            if let index = self.titles.firstIndex(where: { $0.id == title.id }) {
                self.titles[index].protected = on
            }
        }
        // Silence may have come after the recorder made the change. The list is read again once it answers,
        // rather than guessed at.
        if !done, unreachable { titlesLoaded = false }
        // which copy of a set to keep can change with it
        if done, !duplicates.isEmpty { recomputeDuplicates() }
        return done
    }

    /// A write, and not one that can be undone: the recording is gone from the recorder.
    @discardableResult
    func delete(_ title: RecordedTitle) async -> Bool {
        await start()
        // The recorder answers a bare HTTP 500 for a recording it is still writing to, which on screen
        // reads as a fault in the app. The screens do not offer it, but a row can be a few minutes old.
        if title.recording {
            problem = "録画中のため削除できません。番組が終わるまでお待ちください。"
            return false
        }
        guard let client else { return false }
        let deleted = await run("削除中", sending: true) {
            try await client.deleteTitle(id: title.id)
            self.titles.removeAll { $0.id == title.id }
            let capacity = try await client.recordDestinationInfo()
            self.storage = (capacity.freeBytes, capacity.totalBytes)
        }
        // as for protecting: silence may have come after the recording had gone
        if !deleted, unreachable { titlesLoaded = false }
        // A set on screen may have been left with one copy, or none of the one it says it keeps.
        if deleted, !duplicates.isEmpty { recomputeDuplicates() }
        return deleted
    }

    /// Playback happens on the television the recorder is attached to, not here. `pause` toggles, so the same
    /// call resumes. A recorder in network standby answers 880, which is what `needsPower` reports.
    func play(_ title: RecordedTitle, _ operation: String) async {
        await start()
        guard let client else { return }
        needsPower = false
        await run(operation == "stop" ? "停止中" : "再生を指示中") {
            do {
                try await client.playControl(titleID: title.id, operation: operation)
            } catch let error as RecorderError where error.needsPowerOn {
                self.needsPower = true
                throw error
            }
        }
    }

    /// Turns the recorder on, which also turns on the television attached to it.
    func powerOn() async {
        await start()
        guard let client else { return }
        await run("電源を入れています") {
            _ = try await client.powerOn()
            self.needsPower = false
        }
    }

    enum ReservationSort: String, CaseIterable {
        case time, genre, channel

        var label: String {
            switch self {
            case .time: "日時"
            case .genre: "ジャンル"
            case .channel: "局"
            }
        }
    }

    /// The recorder keeps its own automatic recordings alongside the ones an app put in, and so does Sony's
    /// app: two lists rather than one.
    enum ReservationKind: String, CaseIterable {
        case all, mine, automatic

        var label: String {
            switch self {
            case .all: "すべて"
            case .mine: "通常の予約"
            case .automatic: "おまかせ"
            }
        }
    }

    struct ReservationSection: Identifiable {
        var title: String
        var items: [Reservation]
        var id: String { title }
    }

    /// Reservations under a heading: the day they record on, or the genre, or the channel. Soonest first
    /// within each, since a reservation is something that has not happened yet.
    var shownReservations: [Reservation] {
        switch reservationKind {
        case .all: reservations
        case .mine: reservations.filter { !$0.createdByRecorder }
        case .automatic: reservations.filter(\.createdByRecorder)
        }
    }

    var reservationSections: [ReservationSection] {
        let byStart = shownReservations.sorted { $0.start < $1.start }
        switch reservationSort {
        case .time:
            return sections(byStart) { Format.day.string(from: $0.start) }
        case .genre:
            return sections(byStart.sorted { key($0) < key($1) }) {
                $0.genreCode.flatMap { Codes.genreLabel[$0 / 16] } ?? "ジャンルなし"
            }
        case .channel:
            return sections(byStart.sorted { ($0.serviceID, $0.start) < ($1.serviceID, $1.start) }) {
                self.channelName(for: $0)
            }
        }
    }

    private func key(_ reservation: Reservation) -> (Int, Date) {
        (reservation.genreCode ?? 0xFF * 16, reservation.start)
    }

    /// Keeps the headings in the order they first appear, so the sort decides the order of the sections too.
    private func sections(_ reservations: [Reservation],
                          by heading: (Reservation) -> String) -> [ReservationSection] {
        var order: [String] = []
        var grouped: [String: [Reservation]] = [:]
        for reservation in reservations {
            let title = heading(reservation)
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(reservation)
        }
        return order.map { ReservationSection(title: $0, items: grouped[$0] ?? []) }
    }

    /// The reservation that follows this programme, if there is one. Time-only reservations carry no
    /// programme id and so cannot be matched to one.
    func reservation(for program: GuideProgramRow) -> Reservation? {
        guard let broadcastingType = Codes.broadcasting[program.broadcasting] else { return nil }
        return reservationsByProgram[Self.key(broadcastingType, program.serviceID, program.eventID)]
    }

    private static func key(_ broadcastingType: Int, _ serviceID: Int, _ eventID: Int) -> String {
        "\(broadcastingType)-\(serviceID)-\(eventID)"
    }

    /// What would be sent to the recorder to record this programme.
    func request(for program: GuideProgramRow, quality: String, repeating: String) -> ReservationRequest? {
        guard let broadcastingType = Codes.broadcasting[program.broadcasting],
              let qualityCode = Codes.quality[quality],
              let repeatCode = Codes.repeatCodes[repeating] else { return nil }
        return ReservationRequest(title: program.title, start: program.start, durationSec: program.durationSec,
                                  repeatCode: repeatCode, broadcastingType: broadcastingType,
                                  serviceID: program.serviceID, qualityCode: qualityCode,
                                  eventID: program.eventID)
    }

    /// Reservations that would clash. This asks the recorder with the very payload a creation would send, so
    /// it also proves the payload is one the recorder accepts, without recording anything.
    func conflicts(for program: GuideProgramRow, quality: String, repeating: String) async -> [Reservation]? {
        await start()
        guard let client, !unreachable,
              let request = request(for: program, quality: quality, repeating: repeating) else { return nil }
        // Opening a programme is the moment to find out whether the recorder is still up, and to wake it if
        // not, so that the reservation which usually follows goes straight through.
        guard await wakeIfDozing() else { return nil }
        do {
            return try await client.conflicts(elements: XsrsElements.create(request))
        } catch let error as RecorderError {
            if error.unreachable { lostTheRecorder() }
            problem = error.explanation
            return nil
        } catch {
            problem = String(describing: error)
            return nil
        }
    }

    /// Writes to the recorder: after this the box really will record the programme.
    ///
    /// Away from home the recorder is not there to write to, and the programme is still worth keeping: a
    /// reservation that cannot be delivered is queued and sent the next time the recorder answers. Only
    /// silence is queued — a recorder that answers and refuses has said something the reader needs to see —
    /// and only silence before anything was sent. A reservation that went out and met silence may have been
    /// made all the same, and the queue would make it a second time.
    func reserve(_ program: GuideProgramRow, quality: String, repeating: String) async -> Bool {
        await start()
        guard let request = request(for: program, quality: quality, repeating: repeating) else { return false }
        // Known to be away: queue it now rather than spending a timeout finding out again. Thirty seconds
        // of a spinner before "送信待ちにしました" reads as a failure that was then made the best of.
        guard let client, !offline else {
            await queue(request, serviceName: program.serviceName)
            return true
        }
        let activity = activities.begin("予約を登録中")
        defer { activities.end(activity) }
        // A recorder quiet for a while is made sure of first, and woken if it has gone to sleep. When it
        // cannot be, nothing has been sent, so the queue is the place for this.
        guard await wakeIfDozing() else {
            await queue(request, serviceName: program.serviceName)
            return true
        }
        do {
            _ = try await client.createReservation(request)
            problem = nil
            await loadReservations()
            return true
        } catch let error as RecorderError where error.unreachable {
            lostTheRecorder()
            problem = "予約の登録中にレコーダーの応答がなくなりました。届いている場合もあるため、送信待ちにはしていません。"
                + "再接続してから予約一覧で確かめてください。"
            return false
        } catch let error as RecorderError {
            problem = error.explanation
            return false
        } catch {
            problem = String(describing: error)
            return false
        }
    }

    /// The app has gone to the background, which is what makes coming back worth a reconnect. Only this
    /// counts. Control Centre, Notification Centre, the app switcher and a system alert take the app out of
    /// `.active` as well, without it going anywhere, and reconnecting after each of them sent a magic packet
    /// for a glance at the time -- and, with a bulk job running, set a second client talking over the job's.
    func wentToBackground() {
        inBackground = true
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
        // Not after a moment in Control Centre and the like, which went nowhere: see `wentToBackground`.
        guard wasAway else { return }
        // Nor while a check is making sure of the recorder: connecting would make a second client beside the
        // one the check is using. The conflict check has no line of its own to make `busy` say so.
        guard !host.isEmpty, busy == nil, wakeCheck == nil else { return }
        // Not on every flick between apps: without this a glance at something else and back would send a
        // magic packet each time. Any answer counts, not only the connect's.
        if connected, let last = await client?.lastAnswer, Date().timeIntervalSince(last) < 60 { return }
        // Already tried on this very network and got nowhere. Coming back to the app is not news, and
        // spending half a minute waking a recorder that is not there -- every time -- is what made the app
        // look as though it never stopped searching.
        if gaveUp, !networkChanged { return }
        await connect()
    }

    /// The network changed while the app was open: a different Wi-Fi, the VPN coming up, cellular taking
    /// over. That is the one thing that makes another attempt worth making without being asked.
    ///
    /// While connected, it is the one thing that makes the last answer worth nothing: leaving home with the
    /// app open left it looking connected to a recorder it could no longer reach, until something asked and
    /// waited out a timeout. The recorder is asked again with the client in hand, as before an operation.
    func networkChangedWhileOpen() async {
        guard !host.isEmpty, busy == nil, networkChanged else { return }
        guard connected else {
            await connect()
            return
        }
        triedOn = LocalNetwork.signature()
        _ = await wakeIfDozing(evenIfRecent: true)
    }

    // MARK: - reservations waiting for the recorder

    /// Keeps a reservation the recorder never heard, and says so on screen rather than failing.
    private func queue(_ request: ReservationRequest, serviceName: String) async {
        guard let store else { return }
        let waiting = PendingReservation(request: request, serviceName: serviceName)
        // The reader learns that this was finally sent through a notification, and a queued reservation is
        // the first moment that means anything, so this is where the asking belongs.
        await Notify.askIfNeeded()
        do {
            try await store.queue(waiting)
            pending = try await store.pendingReservations()
            problem = nil
            queued = waiting
        } catch {
            problem = String(describing: error)
        }
    }

    func loadPending() async {
        guard let store else { return }
        pending = (try? await store.pendingReservations()) ?? []
    }

    func removePending(_ waiting: PendingReservation) async {
        guard let store else { return }
        try? await store.removePending(waiting.id)
        await loadPending()
    }

    /// Sends what has been waiting, by the rules in `PendingQueue` -- the same ones the overnight run uses.
    /// Called whenever the recorder has just answered, which means from inside `connect()`: nothing here may
    /// await `start()`.
    @discardableResult
    func flushPending() async -> Int {
        guard let client, let store else { return 0 }
        await loadPending()
        guard !pending.isEmpty, !unreachable else { return 0 }
        let activity = activities.begin("送信待ちの予約を登録中")
        let outcome = await PendingQueue.flush(client: client, store: store)
        activities.end(activity)
        // What had not been sent stays queued for the next answer, and the app goes offline as it does for
        // any silence.
        if outcome.interrupted { lostTheRecorder() }
        await loadPending()
        if !outcome.sent.isEmpty { await loadReservationsNow() }
        return outcome.sent.count
    }

    /// Also a write: the recorder forgets the reservation. A recorder that refuses says why, and that reason
    /// is left on screen rather than being reloaded away.
    @discardableResult
    /// Changes the quality or the repeat of a reservation the recorder already holds.
    ///
    /// Found again by what it is rather than by the id in hand, for the same reason a deletion is: the
    /// recorder renumbers its own automatic reservations in blocks. The request keeps everything else,
    /// including the programme id, so a reservation that follows its programme goes on following it.
    func update(_ reservation: Reservation, quality: String, repeating: String) async -> Bool {
        await start()
        guard client != nil else { return false }
        // Sending would only wait out a timeout, from a list that could not be read again first.
        guard !offline else {
            problem = notConnected
            return false
        }
        // The read makes sure of the recorder too, and wakes it if it has gone to sleep.
        await loadReservations()
        guard !offline else { return false }   // the load has said why
        guard let target = current(reservation) else {
            problem = "この予約はすでにレコーダーから削除されていました。一覧を更新しました。"
            return false
        }
        guard let client,
              let qualityCode = Codes.quality[quality],
              let repeatCode = Codes.repeatCodes[repeating] else { return false }
        let request = ReservationRequest(title: target.title, start: target.start,
                                         durationSec: target.durationSec, repeatCode: repeatCode,
                                         broadcastingType: target.broadcastingType, serviceID: target.serviceID,
                                         qualityCode: qualityCode, eventID: target.eventID)
        let activity = activities.begin("予約を変更中")
        defer { activities.end(activity) }
        do {
            try await client.updateReservation(id: target.id, request)
        } catch let error as RecorderError where error.unreachable {
            lostTheRecorder()
            problem = Self.mayHaveArrived
            return false
        } catch let error as RecorderError where error.unknownReservation {
            await loadReservations()
            problem = "レコーダー側で予約が更新されていました。一覧を更新したので、もう一度お試しください。"
            return false
        } catch {
            problem = (error as? RecorderError)?.explanation ?? String(describing: error)
            return false
        }
        problem = nil
        await loadReservations()
        return true
    }

    /// Deletes one reservation, by what it is rather than by the id the app happens to be holding.
    ///
    /// The recorder rewrites the ids of the reservations its own automatic recording made — the whole block
    /// of them at once, when it works through the guide again — so an id read a few hours ago can be dead
    /// while the row on screen still looks right, and deleting it answers 804. Observed on a BDZ-FBT4100:
    /// 19 automatic reservations were renumbered in one go, the programmes themselves unchanged. So read
    /// the list again first and find this reservation by its channel and the moment it starts, which no two
    /// reservations can share. Only when it is not there at all has it really gone.
    func cancel(_ reservation: Reservation) async -> Bool {
        await start()
        guard client != nil else { return false }
        // as for a change: the list has to be read first, and nothing can be read
        guard !offline else {
            problem = notConnected
            return false
        }
        await loadReservations()
        guard !offline else { return false }
        guard let target = current(reservation) else {
            problem = "この予約はすでにレコーダーから削除されていました。一覧を更新しました。"
            return false
        }
        guard let client else { return false }
        let activity = activities.begin("予約を削除中")
        do {
            try await client.deleteReservation(id: target.id)
        } catch let error as RecorderError where error.unreachable {
            activities.end(activity)
            lostTheRecorder()
            problem = Self.mayHaveArrived
            return false
        } catch let error as RecorderError where error.unknownReservation {
            // the list we just read was itself out of date, which is what happens when reading it failed
            activities.end(activity)
            await loadReservations()  // first, because a successful read clears `problem`
            problem = "レコーダー側で予約が更新されていました。一覧を更新したので、もう一度お試しください。"
            return false
        } catch {
            activities.end(activity)
            problem = (error as? RecorderError)?.explanation ?? String(describing: error)
            return false
        }
        activities.end(activity)
        problem = nil
        reservations.removeAll { $0.id == target.id }
        await loadReservations()
        // the reload asks the recorder again, and if it is a moment behind itself the row would come back
        reservations.removeAll { $0.id == target.id }
        return true
    }

    /// The same reservation as the recorder holds it now, whatever it has renumbered it to.
    private func current(_ wanted: Reservation) -> Reservation? {
        reservations.first { $0.id == wanted.id }
            ?? reservations.first { $0.broadcastingType == wanted.broadcastingType
                                    && $0.serviceID == wanted.serviceID
                                    && $0.start == wanted.start }
    }

    func channelName(for reservation: Reservation) -> String {
        channelNames["\(reservation.broadcastingType)-\(reservation.serviceID)"]
            ?? Codes.broadcastingLabel[Codes.broadcasting(code: reservation.broadcastingType) ?? ""]
            ?? "不明な局"
    }

    /// The programme a reservation follows, when it is still in the cached guide.
    func program(for reservation: Reservation) async -> GuideProgramRow? {
        guard let store, let eventID = reservation.eventID,
              let broadcasting = Codes.broadcasting(code: reservation.broadcastingType) else { return nil }
        return try? await store.program(broadcasting: broadcasting, serviceID: reservation.serviceID,
                                        eventID: eventID)
    }

    func reloadFromCache() async {
        guard let store else { return }
        do {
            counts = try await store.counts()
            channels = try await store.channels(broadcasting: broadcasting)
            let everyChannel = try await store.channels(includeHidden: true)
            channelNames = Dictionary(
                everyChannel.compactMap { channel in
                    Codes.broadcasting[channel.broadcasting].map { ("\($0)-\(channel.serviceID)", channel.name) }
                },
                uniquingKeysWith: { first, _ in first })
            channelLogos = Dictionary(
                everyChannel.compactMap { channel in
                    channel.logo.map { ("\(channel.broadcasting)-\(channel.serviceID)", $0) }
                },
                uniquingKeysWith: { first, _ in first })
            programs = try await store.day(day, broadcasting: broadcasting)
        } catch {
            problem = "番組表を読み込めませんでした: \(error)"
        }
    }

    func logo(for program: GuideProgramRow) -> Data? {
        channelLogos["\(program.broadcasting)-\(program.serviceID)"]
    }

    /// A reservation names its channel by the numeric broadcasting type, which the logos are not keyed by.
    /// Stations whose logo the recorder never received have none, so this is often nil on purpose.
    func logo(for reservation: Reservation) -> Data? {
        logo(broadcastingType: reservation.broadcastingType, serviceID: reservation.serviceID)
    }

    func logo(for title: RecordedTitle) -> Data? {
        logo(broadcastingType: title.broadcastingType, serviceID: title.serviceID)
    }

    private func logo(broadcastingType: Int, serviceID: Int) -> Data? {
        Codes.broadcasting(code: broadcastingType)
            .flatMap { channelLogos["\($0)-\(serviceID)"] }
    }

    /// Programmes still to come whose title or description contains this, across every broadcasting type.
    /// The search runs against the cache, so it works away from home too.
    func search(_ query: String) async -> [GuideProgramRow] {
        await start()
        guard let store, query.trimmingCharacters(in: .whitespaces).count >= 1 else { return [] }
        return (try? await store.programs(since: Date(), query: query, limit: 300)) ?? []
    }

    /// The eight days the recorder's guide covers, starting with the broadcast day on air, which until four
    /// in the morning is yesterday's. Kept rather than worked out each time they are read, and replaced by
    /// `followTheClock` only when that first day changes, so that the day strip keeps its chips and its place.
    private(set) var days: [Date]

    /// What the list shows: the day, narrowed to one channel when the reader picked one.
    var filteredPrograms: [GuideProgramRow] {
        guard let serviceFilter else { return programs }
        return programs.filter { $0.serviceID == serviceFilter }
    }

    var channelName: String {
        guard let serviceFilter else { return "すべての局" }
        return channels.first { $0.serviceID == serviceFilter }?.name ?? "すべての局"
    }

    /// Runs one action, keeping whatever went wrong on screen. The message is cleared only by something
    /// that works: clearing it on the way in meant a failure could be wiped by the very next request.
    ///
    /// A recorder that has been quiet a while is made sure of first (`wakeIfDozing`), under the action's own
    /// line, so the screen says what the reader asked for from the moment they asked. Silence on the way
    /// leaves the app offline (`lostTheRecorder`). `sending` marks an action that changes something on the
    /// recorder, which silence leaves unknown rather than undone, and the reader is told so.
    @discardableResult
    private func run(_ what: String, sending: Bool = false, _ work: () async throws -> Void) async -> Bool {
        await run(what, sending: sending) { (_: Activities.Token) in try await work() }
    }

    /// The same, handing the work its own line so that it can say how far it has got.
    @discardableResult
    private func run(_ what: String, sending: Bool = false,
                     _ work: (Activities.Token) async throws -> Void) async -> Bool {
        let activity = activities.begin(what)
        defer { activities.end(activity) }
        guard await wakeIfDozing() else { return false }
        do {
            try await work(activity)
            problem = nil
            return true
        } catch let error as RecorderError where error.unreachable {
            lostTheRecorder()
            problem = sending ? Self.mayHaveArrived : error.explanation
        } catch let error as RecorderError {
            problem = error.explanation
        } catch {
            problem = String(describing: error)
        }
        return false
    }

}
