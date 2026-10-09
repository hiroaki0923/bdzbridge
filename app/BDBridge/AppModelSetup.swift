import Foundation
import RecorderKit
import SwiftUI

/// Choosing the recorder: the demo and leaving it, an address typed in or picked from a scan, and the
/// scan of the subnet itself, which looks for the recorder and the television together.
extension AppModel {
    // MARK: - the demo

    /// Shows the invented recorder, offered in the tutorial to anyone with no recorder to hand (`DemoData`).
    func enterDemo() async {
        guard !demo, canChangeRecorder else { return }
        // A scan still asking behind the local network question has nothing to do with the invented recorder,
        // and the demo is exactly the path that must never raise that question.
        stopScanning()
        // The real television is let go of for the demo's length, or it would answer beside the invented recorder,
        // and so is a registration of it under way: its client id is not to be the demo's.
        dropTVLink()
        tvClientID = nil
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
        // A look still going in the demo would list the invented devices outside it.
        stopScanning()
        host = endDemo()
        await openStore()
        if !host.isEmpty { await connect() }
    }

    /// Turns the demo off, deletes its guide and puts back the MAC from before it, and hands back the address
    /// from before it for the caller to go back to or not: leaving the demo does, choosing a recorder from
    /// inside it does not (see `adopt`). The demo's own MAC is nobody's, so it goes either way.
    ///
    /// The demo's television goes first, whole: its link, which would otherwise stand where the real one's is
    /// made below, then the television, what it was registered with and a registration of it under way. What
    /// waited for it goes with the demo's guide.
    private func endDemo() -> String {
        dropTVLink()
        demoTV = nil
        demoTVCredentials = nil
        demoTVHost = nil
        tvClientID = nil
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

    /// The invented recorder, made the first time the demo needs it and kept for as long as the demo lasts,
    /// because it holds what the reader has done to it: the link's requests and the demo's search both reach
    /// this one.
    func theDemoRecorder() -> DemoRecorder {
        let recorder = demoRecorder ?? DemoRecorder(delay: DemoData.answerDelay)
        demoRecorder = recorder
        return recorder
    }

    /// Takes the recorder at this address, whichever way the reader chose it: from what a scan found, or by
    /// typing it in. Everything that sets a recorder on the reader's say-so comes through here.
    ///
    /// In the demo this is the way out of it as well: the demo ends, its guide with it, and the recorder from
    /// before it is not put back, since the reader has just said which one they want. (Left on, the choice
    /// went to the invented recorder, and was lost when the demo ended.) The MAC from before does come back,
    /// until the new recorder's own replaces it. Not for the invented recorder itself, which the demo's search
    /// finds: chosen, the demo goes on and it is connected to as 再接続 does. Ended, the app would be left
    /// pointing at an invented address through the real transport.
    ///
    /// Outside the demo, any address other than the one in use is another recorder for all the app can tell
    /// before something answers there, and the last one is let go of at the choice (`forgetTheRecorder`): its
    /// lists must not stand over a client that points elsewhere. That includes the same recorder at an
    /// address the router has moved it to, at the cost of reading its lists again. The address in use, chosen
    /// again, forgets nothing and connects as 再接続 does. Only memory goes here; what the phone keeps is
    /// decided by who answers (`RecorderDriver.attach`).
    ///
    /// The televisions the scan found stay listed (`foundTelevisions`): one the tutorial found before a
    /// recorder was chosen there is still to be registered from the settings.
    func adopt(host chosen: String) async {
        guard canChangeRecorder else { return }
        // The reader has chosen, so the rest of the subnet no longer matters -- and a scan left running would
        // put the list back when it finished.
        stopScanning()
        scanOutcome = nil
        found = []
        // The demo's own recorder, chosen from its search, ends nothing and forgets nothing.
        if demo, !RecorderAddress.same(chosen, DemoData.host) {
            _ = endDemo()
            host = chosen
            await openStore()
        } else if !demo {
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
        reservationsRead = nil
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
        // The televisions too: no real one is to be listed in the demo, nor an invented one after it.
        found = []
        foundTelevisions = []
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

    /// Looks through the subnet this device is on for a recorder and a television, as a task of its own that
    /// `stopScanning` can end: the one press, レコーダーとテレビを探す, in place of a way in for each. Each address
    /// is asked both things at once (`DeviceSearch`), and the first time, iOS asks the reader whether the app
    /// may reach the local network. A press looks through the addresses of the Wi-Fi the device is on, once and
    /// at once, with nothing asked before it, and what it found is said as soon as it has. With no Wi-Fi the
    /// scan says so and asks nobody.
    ///
    /// In the demo it asks the demo's invented devices alone, at their own addresses, and reads neither the
    /// Wi-Fi nor the scan's transport (`searchAddresses`, `searchTransport`): nothing goes on the LAN, and the
    /// system's question is never raised there. A real device is found once the demo has ended.
    ///
    /// Unless that look was turned away (`ScanTally.Counts.mostTurnedAway`): the requests of it the system
    /// turned away outnumber all the rest together, which on a subnet, where the addresses nobody lives at time
    /// out, is taken for a look of which nothing left the device but what the system lets through unasked. The
    /// system "may deny the operation immediately, before the user has responded to the alert" (TN3179), and on
    /// one phone, on 2026-10-06, a first press's look came back with 252 requests turned away at once and one
    /// refused (`docs/porting.md`). A look that found a recorder or a television is said all the same,
    /// whatever its counts: something got out, as it should when the permission is given while the look goes
    /// (not seen). Otherwise nothing is said of having looked. The notice about the permission goes up, and the
    /// scan asks again, once a second, at the address the look saw turned away first (`ScanTally.turnedAwayAt`,
    /// `Discovery.turnedAway`) until a request is let out: for what cannot wait for connectivity, the technote
    /// says "add appropriate retry logic". Then the notice comes down and it looks again, and what that look
    /// comes to is treated the same way. One count over both kinds of request reads the look, since the
    /// permission is the app's and not a port's; the address asked again is one whose recorder's request was
    /// turned away, and the request is the recorder's, so it asks again exactly what was turned away.
    ///
    /// Never at the address that refused, nor at one fixed beforehand, nor at one whose only request turned
    /// away was the television's: the address let through unasked is asked at port 80 too, and may fail there
    /// with a code read as turned away. The one address on a subnet that was let through behind the question,
    /// on that phone, was the one that refused, and the technote names such addresses: "If your device's DNS
    /// server is on a local network, traffic to it doesn't require local network access." A request to an
    /// address the system turned away is turned away while the permission is in the way, and is let out once
    /// it is given, as the technote says of every operation: "If your program has local network access, the
    /// system allows the operation. If not, the system blocks it." Not yet seen on a phone for the request
    /// asked again.
    ///
    /// The Wi-Fi is read again before each of those requests, and before the look after one that got out: the
    /// reader may be minutes over the system's question, and the device off the Wi-Fi or on another by the end
    /// of them. With none, the scan says there is no Wi-Fi and asks nobody more. On another subnet, nothing
    /// is sent to the one the look was made on: the look is made again at once on the new one, in place of
    /// that turn's request, and what it comes to is treated the same way.
    ///
    /// That does not go on without end. The loop is a `for` over the single requests one press is allowed
    /// (`singleRequestsAllowed`): each turn of it makes at most one single request and at most one look, and
    /// nothing gives a turn back, so after its first look a press comes to at most that many single requests
    /// and that many looks. Then the scan ends: the notice stays, nothing is said of having looked, and the
    /// button is the reader's.
    ///
    /// What the scan did goes to the log as it goes (`ScanLog`), in counts and codes, the single requests'
    /// among them -- how the one that got out came back, and the first turned away -- since what the system
    /// does behind its question is seen nowhere but on a phone.
    func scanForDevices() {
        scanTask?.cancel()
        scanTask = Task { await scan() }
    }

    /// Ends a scan wherever it has got to: a look, and the single requests after one that was turned away.
    func stopScanning() {
        if scanTask != nil { surroundings.scanLog("stopped") }
        scanTask?.cancel()
        scanTask = nil
        scanRun += 1
        scanning = nil
        scanBlocked = false
    }

    /// How many single requests one press may come to after a look that was turned away: two minutes of them, a
    /// second apart.
    static let singleRequestsAllowed = 120

    private func scan() async {
        scanRun += 1
        let run = scanRun
        // whatever the last attempt left on screen is not about this one
        problem = nil
        scanOutcome = nil
        scanBlocked = false
        found = []
        foundTelevisions = []
        // The interfaces, the transport and the pause are the surroundings' (`Surroundings`), the device's own
        // in the app: a test presses the button on a Wi-Fi it has invented. The demo's own in the demo.
        guard let pressed = wifiToLookRound() else {
            surroundings.scanLog("press: no Wi-Fi to look round")
            // No scan is under way once this is said, here and where it is said later (`wifiStillThere`): the
            // log is not to go on writing the app's phases, and a stop, for one.
            scanTask = nil
            report(.noWiFi)
            return
        }
        let active = appIsActive ? "active" : "not active"
        surroundings.scanLog("press: \(pressed.count) addresses to ask, the app \(active)")
        guard case .turnedAway(var asking) = await look(through: pressed, run) else { return }
        // The look was turned away, and the notice is up. The address it saw turned away first is asked, a
        // second apart, through a transport of the scan's own kind, until a request is let out; nothing in
        // between takes the notice down, and a look that follows puts it back if it is turned away as well. How
        // a request came back goes to the log in its status or code: the one that got out, and the first turned
        // away, which the rest that are would only repeat.
        let transport = searchTransport()
        var turnedAwayWritten = false
        for single in 1...Self.singleRequestsAllowed {
            await surroundings.scanPause(.seconds(1))
            guard scanRun == run, !Task.isCancelled, let wifi = wifiStillThere() else { return }
            // The device is on another subnet now, or the address is its own: nothing of the last look is
            // asked of it. The look is made again on the Wi-Fi it is on, as this turn's.
            guard wifi.contains(asking) else {
                surroundings.scanLog("single request: none, on another Wi-Fi; looked again, turn \(single)")
                guard case .turnedAway(let next) = await look(through: wifi, run) else { return }
                asking = next
                continue
            }
            let request = ScanTally(transport)
            let turnedAway = await Discovery.turnedAway(at: asking, transport: request)
            // A request ended by the scan being stopped comes back as one that was out.
            guard scanRun == run, !Task.isCancelled else { return }
            let cameBack = await request.counts.statusesAndCodes
            guard !turnedAway else {
                if !turnedAwayWritten {
                    surroundings.scanLog("single request: turned away (\(cameBack)), written for the first only")
                    turnedAwayWritten = true
                }
                continue
            }
            surroundings.scanLog("single request: got out (\(cameBack)), after \(single)")
            scanBlocked = false
            guard let again = wifiStillThere() else { return }
            guard case .turnedAway(let next) = await look(through: again, run) else { return }
            asking = next
        }
        // Every single request the press is allowed has been made. The notice stays, nothing is said of
        // having looked, and the button is the reader's.
        surroundings.scanLog("single requests: given up after \(Self.singleRequestsAllowed)")
        scanning = nil
        scanTask = nil
    }

    /// The addresses of the Wi-Fi the device is on at this moment, for a scan to ask. Nil on none.
    private func wifiToLookRound() -> [String]? {
        let hosts = searchAddresses()
        return hosts.isEmpty ? nil : hosts
    }

    /// What a scan looks round: the addresses of the Wi-Fi, or in the demo the demo's own devices' addresses,
    /// with the interfaces never read.
    private func searchAddresses() -> [String] {
        guard !demo else { return [DemoData.host, DemoData.tvHost] }
        return surroundings.lanInterfaces().flatMap { LocalNetwork.hosts(around: $0) }
    }

    /// What a scan sends its requests through: the surroundings' session, made anew for each look, or in the
    /// demo the demo's devices, with the session never made.
    private func searchTransport() -> any HTTPTransport {
        guard demo else { return surroundings.scanTransport() }
        return DemoDevices(recorder: theDemoRecorder(), television: televisionTransport(DemoData.tvHost))
    }

    /// The same, for a scan that has got past the press. On none the scan is over: that is said, nobody is
    /// asked, and the notice about the permission comes down, since what is in the way is the Wi-Fi.
    private func wifiStillThere() -> [String]? {
        if let wifi = wifiToLookRound() { return wifi }
        surroundings.scanLog("no Wi-Fi left to look round")
        scanBlocked = false
        scanning = nil
        scanTask = nil
        report(.noWiFi)
        return nil
    }

    /// How one look through the addresses ended: over, with what it found said or the scan stopped meanwhile,
    /// or turned away, with nothing said, the notice about the permission up, and the address it saw turned
    /// away first, to ask again.
    private enum Look {
        case over
        case turnedAway(at: String)
    }

    /// One look through the addresses, each asked once of each kind, and what was found said as soon as it is
    /// over. A look that was turned away says nothing and puts the notice about the permission up instead: the
    /// scan is still under way then, and what comes next is the caller's.
    private func look(through hosts: [String], _ run: Int) async -> Look {
        scanning = (0, hosts.count)
        // A device shows up the moment it answers, so the reader can take it while the rest of the subnet is
        // still being tried. One tally counts both kinds; the address it keeps is from the recorder's.
        let transport = ScanTally(searchTransport(), keepingAddressFrom: Upnp.port)
        let began = ContinuousClock.now
        let result = await DeviceSearch.scan(hosts: hosts, transport: transport, progress: { done, total in
            Task { @MainActor in
                guard self.scanRun == run, self.scanning != nil else { return }
                self.scanning = (done, total)
            }
        }, found: { sighting in
            Task { @MainActor in
                guard self.scanRun == run else { return }
                self.list(sighting)
            }
        })
        // How the requests came back, how many of each kind that made and how long it took, for the log.
        let seconds = String(format: "%.2f", (ContinuousClock.now - began) / .seconds(1))
        let counts = await transport.counts
        let turnedAwayAt = await transport.turnedAwayAt
        let stopped = scanRun != run || Task.isCancelled
        surroundings.scanLog("search: \(counts.summary); recorders \(result.recorders.count); "
                             + "televisions \(result.televisions.count); \(seconds) s" + (stopped ? "; stopped" : ""))
        guard !stopped else { return .over }
        // A look that was turned away and found nobody is not to be said: nothing of it is taken to have left
        // the device but what the system lets through unasked. One that found a recorder or a television is
        // said, whatever the counts. A look turned away has at least one address the system turned away, the
        // first of which the tally kept, to ask again.
        if counts.mostTurnedAway, result.isEmpty, let turnedAwayAt {
            surroundings.scanLog("search: turned away, nothing said; one address is asked a second")
            scanBlocked = true
            return .turnedAway(at: turnedAwayAt)
        }
        // The lists stay in the order the devices answered, which the reader has been looking at while the
        // scan ran: the scan's own lists are in the order of the addresses as text, and would move the row
        // under a finger about to tap it. Anything it found whose row has not arrived yet goes at the end.
        for recorder in result.recorders { list(.recorder(recorder)) }
        for television in result.televisions { list(.television(television)) }
        // A look made again on another Wi-Fi is made with the notice up; what it found is said in its place.
        scanBlocked = false
        scanning = nil
        scanTask = nil
        let devices = found.count + foundTelevisions.count
        surroundings.scanLog(devices == 0 ? "said: nothing found" : "said: found \(devices)")
        report(devices == 0 ? .nothing : .found(recorders: found.count, televisions: foundTelevisions.count))
        return .over
    }

    /// Puts what a scan found at the end of its list, unless its address is there already.
    private func list(_ sighting: Sighting) {
        switch sighting {
        case .recorder(let recorder):
            if !found.contains(where: { $0.host == recorder.host }) { found.append(recorder) }
        case .television(let television):
            if !foundTelevisions.contains(where: { $0.host == television.host }) {
                foundTelevisions.append(television)
            }
        }
    }

    /// Whether a recorder a scan found is the one the app is set to. By its UDN as well as its address, so
    /// that it is marked once the router has moved it and before the app has followed. In the demo, the
    /// invented recorder its search finds.
    func inUse(_ recorder: RecorderDescription) -> Bool {
        if demo { return recorder.host == DemoData.host }
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

    /// What a scan came to, in the package's words (`DeviceSearch.Outcome`): what was found of each kind,
    /// nothing, or no Wi-Fi.
    typealias ScanOutcome = DeviceSearch.Outcome
}
