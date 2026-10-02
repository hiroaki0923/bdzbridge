import Foundation
import RecorderKit
import SwiftUI

/// Choosing the recorder: the demo and leaving it, an address typed in or picked from a scan, and the
/// scan of the subnet itself.
extension AppModel {
    // MARK: - the demo

    /// Shows the invented recorder. Offered in the tutorial, because the first thing the app asks for is a
    /// recorder on the network, and not everyone has one to hand when they are deciding whether this is
    /// worth setting up -- the reviewer who has to judge it least of all.
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
    /// In the demo this is also the way out of it. Connecting went through the invented recorder whatever
    /// the address, so choosing a real one left the screens the demo's, said it had connected and closed the
    /// tutorial; ending the demo afterwards then put back the recorder from before it -- none at all, for
    /// somebody who tried the demo first -- and the one just chosen was gone. Trying the demo and then
    /// setting up the real thing is the likeliest way for anyone new to arrive, so the demo ends here, its
    /// guide with it, and the recorder from before is not put back: the reader has just said which one they
    /// want. The MAC from before does come back, as it would have stayed had the address been typed outside
    /// the demo; `macWasReadHere` keeps it from sending the search after the wrong recorder, and the new one's
    /// own replaces it as soon as it answers.
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
            host = chosen
        }
        await connect()
    }

    /// Opens the cache that belongs to whichever recorder is in play now, and forgets everything the other
    /// one said.
    private func openStore() async {
        session.forgotTheDevice()
        client = nil
        reservations = []
        titles = []
        titlesLoaded = false
        recorderRules = []
        recorderRulesLoaded = false
        recorderRulesFailure = nil
        pending = []
        flushReport = nil
        duplicates = []
        duplicatePicks = []
        unreadDuplicates = 0
        summaries = [:]
        fixedBlurbs = []
        problem = nil
        found = []
        scanOutcome = nil
        accessWatch?.cancel()
        accessWatch = nil
        store = (try? guidePath()).flatMap { try? GuideStore(path: $0) }
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
        // The list stays in the order the recorders answered, which is the order the reader has been looking
        // at while the scan ran. Taking the scan's own list here put it in the order of the addresses as text
        // -- .100 before .63 -- and moved the row under a finger about to tap it. Anything the scan found whose
        // row has not arrived yet goes at the end.
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

        /// What usually lies behind finding nothing, for the reader to go through. A single line asking them
        /// to check the power and the Wi-Fi left out the two causes nobody would think of: a guest network,
        /// and a recorder that is not one of Sony's BDZ series.
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
