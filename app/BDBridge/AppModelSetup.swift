import Foundation
import RecorderKit
import SwiftUI

/// Choosing the recorder: the demo and leaving it, an address typed in or picked from a scan, and the
/// scan of the subnet itself.
extension AppModel {
    // MARK: - the demo

    /// Shows the invented recorder, offered in the tutorial to anyone with no recorder to hand (`DemoData`).
    func enterDemo() async {
        guard !demo, canChangeRecorder else { return }
        // A scan still waiting on the local network question has nothing to do with the invented recorder,
        // and the demo is exactly the path that must never raise that question.
        stopScanning()
        // The real television is let go of for the demo's length, or it would answer beside the invented recorder.
        dropTVLink()
        DemoData.turnOn(realHost: host, realMac: mac, in: defaults)
        demo = true
        await openStore()
        host = DemoData.host
        remember(mac: DemoData.mac)
        await connect()
    }

    /// Puts back whatever was there before, and takes the demo's guide with it: the invented programmes live
    /// in their own database, which is deleted here rather than left to be mistaken for a real one.
    func leaveDemo() async {
        guard demo, canChangeRecorder else { return }
        host = endDemo()
        await openStore()
        if !host.isEmpty { await connect() }
    }

    /// Turns the demo off, deletes its guide and puts back the MAC from before it, and hands back the address
    /// from before it for the caller to go back to or not: leaving the demo does, choosing a recorder from
    /// inside it does not (see `adopt`). The demo's own MAC is nobody's, so it goes either way.
    private func endDemo() -> String {
        let before = DemoData.turnOff(in: defaults)
        demo = false
        demoRecorder = nil
        if let folder = try? surroundings.folder() { Storage.removeDemoGuide(in: folder) }
        if let mac = before.mac { remember(mac: mac) } else { forgetMac() }
        // The real television, when one is saved, comes back with the real recorder.
        makeTVLink()
        if let tv { Task { await tv.connect() } }
        return before.host
    }

    /// Takes the recorder at this address, whichever way the reader chose it: from what a scan found, or by
    /// typing it in. Everything that sets a recorder on the reader's say-so comes through here.
    ///
    /// In the demo this is the way out of it as well: the demo ends, its guide with it, and the recorder from
    /// before it is not put back, since the reader has just said which one they want. (Left on, the choice
    /// went to the invented recorder, and was lost when the demo ended.) The MAC from before does come back,
    /// until the new recorder's own replaces it.
    ///
    /// Outside the demo, any address other than the one in use is another recorder for all the app can tell
    /// before something answers there, and the last one is let go of at the choice (`forgetTheRecorder`): its
    /// lists must not stand over a client that points elsewhere. That includes the same recorder at an
    /// address the router has moved it to, at the cost of reading its lists again. The address in use, chosen
    /// again, forgets nothing and connects as 再接続 does. Only memory goes here; what the phone keeps is
    /// decided by who answers (`RecorderDriver.attach`).
    func adopt(host chosen: String) async {
        guard canChangeRecorder else { return }
        // The reader has chosen, so the rest of the subnet no longer matters -- and a scan left running would
        // put the list back when it finished.
        stopScanning()
        scanOutcome = nil
        found = []
        if demo {
            _ = endDemo()
            host = chosen
            await openStore()
        } else {
            // Before the address is set, and with nothing awaited between this and the connect: no screen
            // gets a turn in which the last recorder's lists stand over the new address.
            if !RecorderAddress.same(chosen, host) { forgetTheRecorder() }
            host = chosen
        }
        await connect()
    }

    /// Lets go of the recorder in play as far as memory goes: what it said of itself and which it was, the
    /// client that asked it, a wait for the permission at it, and the lists the app holds of it. Until the next
    /// connect there is no client, so nothing can be sent from a list that is no longer there. The queue, the
    /// MAC and what the phone keeps are left: those are decided when a recorder answers
    /// (`RecorderDriver.attach`).
    func forgetTheRecorder() {
        recorder.forgetTheDevice()
        forgetWhatTheRecorderSaid()
        problem = nil
    }

    /// Empties what the app holds in memory that a recorder said: its lists, the sets of copies with their
    /// ticks and the texts they were built on, the last job, and the lists' filters. Each recorder numbers
    /// its own, so a row left from one would be sent, by its number, to the next. For a choice
    /// (`forgetTheRecorder`), and for another recorder answering where nobody chose one
    /// (`anotherDeviceDescribedItself`); the screens are told (`timesForgotten`).
    ///
    /// A finished job goes because the duplicates view takes it for having looked. One still running is
    /// stopped by the check that hears the other recorder (`anotherAnsweredTheCheck`).
    func forgetWhatTheRecorderSaid() {
        reservations = []
        titles = []
        titlesLoaded = false
        recorderRules = []
        recorderRulesLoaded = false
        recorderRulesFailure = nil
        flushReport = nil
        anotherTookOver = false
        duplicates = []
        duplicatePicks = []
        unreadDuplicates = 0
        summaries = [:]
        fixedBlurbs = []
        clearJob()
        titleGenre = nil
        titleState = nil
        reservationKind = .all
        timesForgotten += 1
    }

    /// Opens the cache that belongs to whichever recorder is in play now, the demo's or a real one's, and
    /// forgets everything the other one said. The queue shown is the one in the cache opened.
    private func openStore() async {
        forgetTheRecorder()
        pending = []
        // What a scan found, which a choice clears for itself (`adopt`). Not with the recorder: that is also
        // let go of when another answers a check, under a list of found recorders the reader may be reading.
        found = []
        scanOutcome = nil
        store = (try? guidePath()).flatMap {
            try? GuideStore(path: $0, busyTimeoutMilliseconds: surroundings.storeBusyTimeoutMilliseconds)
        }
        if let store {
            if demo { try? await DemoData.seed(store: store) }
            await reloadFromCache()
            await loadPending()
        }
    }

    /// Looks through the subnet this device is on for a recorder, as a task of its own that `stopScanning`
    /// can end. One short request per address, and the first time, iOS asks the reader whether the app may
    /// reach the local network. The scan waits for that answer before it starts
    /// (`LocalNetwork.waitForAccess`): the system may turn a request away at once behind its question, and a
    /// scan made there has said it found nobody while the question was still up. Then it looks through the
    /// addresses once, and what it found is said as soon as it has.
    ///
    /// The addresses are those of the Wi-Fi the device is on when the look is made, read again after the wait
    /// and not taken from the press: a reader may be minutes over the system's question, and the device off
    /// the Wi-Fi or on another by the end of them. With none by then the scan says there is no Wi-Fi and asks
    /// nobody, whatever the wait answered.
    ///
    /// Unless that look was turned away whole (`ScanTally.Counts.turnedAwayWhole`): not one request of it
    /// answered, timed out, refused or dropped, which on a subnet, where the addresses nobody lives at time
    /// out, is taken for a look of which nothing left the device. The wait can be wrong behind the system's
    /// question -- what its connection is while the question is up is not in what Apple has written
    /// (`docs/porting.md`) -- and this is the net under it. Nothing is said of having looked. The notice
    /// about the permission goes up, and the scan asks one address once a second (`Discovery.turnedAway`)
    /// until a request is let out; then the notice comes down and it looks again, and what that look comes
    /// to is treated the same way. The Wi-Fi is read again before each of those requests, which goes to the
    /// neighbour on it, and before the look after one that got out.
    ///
    /// That does not go on without end. The loop is a `for` over the single requests one press is allowed
    /// (`singleRequestsAllowed`): each turn of it makes one of them and at most one look after it, and
    /// nothing gives a turn back, so a press comes to at most that many single requests and one look more
    /// than that. Then the scan ends as it does when the wait gives up: the notice stays, nothing is said of
    /// having looked, and the button is the reader's.
    ///
    /// What the scan did goes to the log as it goes (`ScanLog`), in counts and codes: what the system does
    /// behind its question is seen nowhere but on a phone.
    func scanForRecorders() {
        scanTask?.cancel()
        scanTask = Task { await scan() }
    }

    /// Ends a scan wherever it has got to: the wait for the permission, a look, and the single requests
    /// after one that was turned away.
    func stopScanning() {
        if scanTask != nil { surroundings.scanLog("stopped") }
        scanTask?.cancel()
        scanTask = nil
        scanRun += 1
        scanning = nil
        scanBlocked = false
    }

    /// How many single requests one press may come to after a look that was turned away whole: two minutes
    /// of them, a second apart, which is as long as the wait for the permission goes on making connections
    /// (`LocalNetwork.turnsAllowed`).
    static let singleRequestsAllowed = 120

    private func scan() async {
        scanRun += 1
        let run = scanRun
        // whatever the last attempt left on screen is not about this one
        problem = nil
        scanOutcome = nil
        scanBlocked = false
        found = []
        // The interfaces, the wait, the transport and the pause are the surroundings' (`Surroundings`), the
        // device's own in the app: a test presses the button on a Wi-Fi it has invented.
        guard let pressed = wifiToLookRound() else {
            surroundings.scanLog("press: no Wi-Fi to look round")
            // No scan is under way once this is said, here and where it is said later (`wifiStillThere`): the
            // log is not to go on writing the app's phases, and a stop, for one.
            scanTask = nil
            report(.noWiFi)
            return
        }
        let active = appIsActive ? "active" : "not active"
        surroundings.scanLog("press: \(pressed.hosts.count) addresses to ask, the app \(active)")
        scanning = (0, pressed.hosts.count)
        let access = await surroundings.waitForLocalNetwork(pressed.neighbour) { @MainActor [weak self] in
            guard let self, self.scanRun == run else { return }
            self.scanBlocked = true
        }
        guard scanRun == run, !Task.isCancelled else { return }
        let over = switch access {
        case .allowed: "allowed"
        case .blocked: "given up, the permission still in the way"
        case .unavailable: "no path, and not for the permission"
        }
        surroundings.scanLog("the wait for the permission is over: \(over)")
        // The wait has given up with the permission still in the way. Nobody was asked, so nothing is said
        // of having looked: the notice the wait put up stays, with its way to the Settings app, and the
        // button is the reader's again.
        if access == .blocked {
            scanning = nil
            scanTask = nil
            return
        }
        scanBlocked = false
        // Whatever else the wait answered: allowed, or no path for another reason than the permission. Either
        // way the Wi-Fi may have gone or changed since the press. Where it is still there the look is made,
        // through the addresses it has now, and read as any other.
        guard let wifi = wifiStillThere() else { return }
        guard await look(through: wifi.hosts, run) == .turnedAway else { return }
        // The look was turned away whole, and the notice is up. One address is asked, a second apart, through
        // a transport of the scan's own kind, until a request is let out; nothing in between takes the notice
        // down, and the look that follows puts it back if it is turned away as well.
        let transport = surroundings.scanTransport()
        for single in 1...Self.singleRequestsAllowed {
            await surroundings.scanPause(.seconds(1))
            guard scanRun == run, !Task.isCancelled, let asking = wifiStillThere() else { return }
            let turnedAway = await Discovery.turnedAway(at: asking.neighbour, transport: transport)
            // A request ended by the scan being stopped comes back as one that was out.
            guard scanRun == run, !Task.isCancelled else { return }
            guard !turnedAway else { continue }
            surroundings.scanLog("single request: got out, after \(single)")
            scanBlocked = false
            guard let again = wifiStillThere() else { return }
            guard await look(through: again.hosts, run) == .turnedAway else { return }
        }
        // Every single request the press is allowed has been made. The notice stays, nothing is said of
        // having looked, and the button is the reader's, as when the wait gives up.
        surroundings.scanLog("single requests: given up after \(Self.singleRequestsAllowed)")
        scanning = nil
        scanTask = nil
    }

    /// The Wi-Fi the device is on at this moment, as a scan needs it: somebody on it to aim at
    /// (`LocalNetwork.neighbour`), and the addresses to ask. Nil on none.
    private func wifiToLookRound() -> (neighbour: String, hosts: [String])? {
        let lan = surroundings.lanInterfaces()
        let hosts = lan.flatMap { LocalNetwork.hosts(around: $0) }
        guard let neighbour = lan.lazy.compactMap(LocalNetwork.neighbour(on:)).first, !hosts.isEmpty else {
            return nil
        }
        return (neighbour, hosts)
    }

    /// The same, for a scan that has got past the press. On none the scan is over: that is said, nobody is
    /// asked, and the notice about the permission comes down, since what is in the way is the Wi-Fi.
    private func wifiStillThere() -> (neighbour: String, hosts: [String])? {
        if let wifi = wifiToLookRound() { return wifi }
        surroundings.scanLog("no Wi-Fi left to look round")
        scanBlocked = false
        scanning = nil
        scanTask = nil
        report(.noWiFi)
        return nil
    }

    /// How one look through the addresses ended: over, with what it found said or the scan stopped
    /// meanwhile, or turned away whole, with nothing said and the notice about the permission up.
    private enum Look {
        case over
        case turnedAway
    }

    /// One look through the addresses, each asked once, and what was found said as soon as it is over.
    /// A look that was turned away whole says nothing and puts the notice about the permission up instead:
    /// the scan is still under way then, and what comes next is the caller's.
    private func look(through hosts: [String], _ run: Int) async -> Look {
        scanning = (0, hosts.count)
        // a recorder shows up the moment it answers, so the reader can take it while the rest of the
        // subnet is still being tried
        let transport = ScanTally(surroundings.scanTransport())
        let began = ContinuousClock.now
        let result = await Discovery.scan(hosts: hosts, transport: transport, progress: { done, total in
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
        // How the requests came back, how many recorders that made and how long it took, for the log.
        let seconds = String(format: "%.2f", (ContinuousClock.now - began) / .seconds(1))
        let counts = await transport.counts
        let stopped = scanRun != run || Task.isCancelled
        surroundings.scanLog("search: \(counts.summary); recorders \(result.count); \(seconds) s"
                             + (stopped ? "; stopped" : ""))
        guard !stopped else { return .over }
        // Nobody answered a look that was turned away whole, so it found nobody, and that is not to be said:
        // nothing of it is taken to have left the device.
        if counts.turnedAwayWhole {
            surroundings.scanLog("search: turned away whole, nothing said; one address is asked a second")
            scanBlocked = true
            return .turnedAway
        }
        // The list stays in the order the recorders answered, which the reader has been looking at while the
        // scan ran: the scan's own list is in the order of the addresses as text, and would move the row
        // under a finger about to tap it. Anything it found whose row has not arrived yet goes at the end.
        for recorder in result where !found.contains(where: { $0.host == recorder.host }) {
            found.append(recorder)
        }
        scanning = nil
        scanTask = nil
        surroundings.scanLog(found.isEmpty ? "said: nothing found" : "said: found \(found.count)")
        report(found.isEmpty ? .nothing : .found(found.count))
        return .over
    }

    /// Whether a recorder a scan found is the one the app is set to. By its UDN as well as its address, so
    /// that it is marked once the router has moved it and before the app has followed.
    func inUse(_ recorder: RecorderDescription) -> Bool {
        guard !demo else { return false }
        if recorder.host == host { return true }
        guard let info, !info.udn.isEmpty else { return false }
        return recorder.udn == info.udn
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
            case .nothing: "レコーダーが見つかりませんでした"
            case .noWiFi: "Wi-Fi に接続されていません。レコーダーと同じ Wi-Fi につないでから、もう一度お試しください。"
            }
        }

        /// What usually lies behind finding nothing, for the reader to go through. Two of them nobody would
        /// think of: a guest network, and a recorder that is not one of Sony's BDZ series.
        ///
        /// Nothing here says a recorder in standby cannot be found. It answers in network standby; what goes
        /// silent is one left off a while, which leaves the network (`docs/porting.md`).
        var causes: [String] {
            guard self == .nothing else { return [] }
            return [
                "レコーダーがネットワークから外れている。電源を切ってしばらくたつと外れることがあるので、"
                    + "電源を入れてから探し直してください。",
                "iPhone が、ゲスト用の Wi-Fi など、レコーダーとは別のネットワークにつながっている。",
                "レコーダーがネットワークにつながっていない。レコーダー本体のネットワーク設定で確認できます。",
                "ソニーの BDZ シリーズ以外のレコーダー。このアプリは BDZ シリーズ専用です。",
            ]
        }

        var failed: Bool {
            if case .found = self { return false }
            return true
        }
    }
}
