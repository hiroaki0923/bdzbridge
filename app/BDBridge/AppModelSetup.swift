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
        store = (try? guidePath()).flatMap { try? GuideStore(path: $0) }
        if let store {
            if demo { try? await DemoData.seed(store: store) }
            await reloadFromCache()
            await loadPending()
        }
    }

    /// Looks through the subnet this device is on for a recorder, as a task of its own that `stopScanning`
    /// can end. One short request per address, and the first time, iOS asks the reader whether the app may
    /// reach the local network. The scan waits for that answer before it starts: behind the question every
    /// request fails at once, and the scan would come back with nothing.
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
        // The list stays in the order the recorders answered, which the reader has been looking at while the
        // scan ran: the scan's own list is in the order of the addresses as text, and would move the row
        // under a finger about to tap it. Anything it found whose row has not arrived yet goes at the end.
        for recorder in result where !found.contains(where: { $0.host == recorder.host }) {
            found.append(recorder)
        }
        scanning = nil
        scanTask = nil
        report(found.isEmpty ? .nothing : .found(found.count))
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
