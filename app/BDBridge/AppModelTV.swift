import Foundation
import RecorderKit

/// The television: its link, made when one is saved, and the steps that add it -- finding it at an address,
/// registering with it by the PIN it shows -- and take it away.
///
/// It has a link of its own beside the recorder's (`DeviceLink` with a `TVDriver`), told the same things --
/// the app coming back, the network changing -- and answering to a host of its own (`TVHost`), so that neither
/// device's silence, problem or wait for the local network permission is the other's. What the television said
/// is kept by that host too -- its reservations, and what became of what waited for it -- and goes when the
/// link is let go of.
///
/// In the demo the real television is let go of, or it would answer beside the invented recorder, and the
/// demo's own is the one in play once the reader adds it (`theDemoTV`): reached in memory, registered in
/// memory, and never through the surroundings' way to the LAN or their Keychain (`televisionTransport`,
/// `televisionCredentials`). What is saved of the real one, and what the runs with no screen told of it, are
/// left as they are.
extension AppModel {
    var tvDriver: TVDriver? { tv?.driver as? TVDriver }

    /// What the television is listed as among the devices registered with it.
    static let tvNickname = "BD Bridge"

    /// The line that says what went wrong with a device, for whatever shows a reservation's failure: the
    /// recorder's is the model's own, the television's its host's. Each device's operations write to its own.
    func problem(for device: DeviceSlot) -> String? {
        device == .tv ? tvHost?.problem : problem
    }

    /// Whether a device is busy, for the buttons that write to the device a reservation is held by: the
    /// recorder's work is the model's own (`isBusy`), the television's its host's, and neither holds back a
    /// button of the other's. A television the app has let go of counts as busy: a row of its still on a
    /// screen has nothing to be sent to.
    func isBusy(for device: DeviceSlot) -> Bool {
        device == .tv ? tvHost?.isBusy ?? true : isBusy
    }

    /// What the strip says became of what was waiting: the recorder's sending and then the television's,
    /// joined with a full stop as the sentences of one are. Each is kept apart (`flushReport`, the host's
    /// `report`), so that neither device's sending writes over what the other's said. With no television
    /// saved it is the recorder's alone, as it has always read.
    var queueReport: String? {
        let said = [flushReport, tvHost?.report].compactMap { $0 }
        return said.isEmpty ? nil : said.joined(separator: "。")
    }

    /// Both go: the reader closed the line, or left the app.
    func closeQueueReport() {
        flushReport = nil
        tvHost?.report = nil
    }

    /// Whether the television's disk is away and a reservation is waiting for it to come back: what the
    /// strip and the reservations tab say the disk for (`TVDriver.diskNotFound`). The disk is as the driver
    /// last knew it, from an attach or from a sending since. Only a row with no reason on it waits for the
    /// disk: one with a reason waits for the reader, and is not sent when the disk is back either.
    var tvWaitsForItsDisk: Bool {
        tvDriver?.facts.storage?.mounted == false
            && pending.contains { $0.target == .tv && $0.problem == nil }
    }

    /// Makes the television's link from what is saved, when a television is saved -- in the demo, the demo's
    /// once it is added: known by the MAC saved with it from the first answer, and renewing its registration
    /// only with the app in front. Connects nothing.
    func makeTVLink() {
        guard tv == nil, let host = savedTVHost else { return }
        let owner = TVHost(model: self)
        let driver = TVDriver(credentials: televisionCredentials(), nickname: Self.tvNickname,
                              inFront: { [weak self] in self.map { !$0.inBackground } ?? false })
        let link = DeviceLink(host: host, session: SessionState(device: savedTVMac),
                              driver: driver, environment: tvLinkEnvironment())
        link.owner = owner
        owner.link = link
        tvHost = owner
        tv = link
    }

    /// Lets go of the television's link, and of a wait for the permission it had set going. What the television
    /// said goes with its host -- its reservations, and its line of what went wrong -- so no list is emptied
    /// here; the screens are told that it went (`tvTimesForgotten`), when there was a link to let go of. The
    /// lines its host had up are on the model's own list, and come down now rather than when the requests
    /// they stand for end: what is still out on a television the app has let go of says nothing on the screens.
    func dropTVLink() {
        if tv != nil { tvTimesForgotten += 1 }
        tvHost?.stopWaitingForPermission()
        tvHost?.takeDownLines()
        tv = nil
        tvHost = nil
    }

    /// The LAN as the television's link sees it: requests by the television's transport (`televisionTransport`),
    /// the permission asked about as the recorder's link asks, and a television that moved looked for as the
    /// recorder's link looks for a recorder -- never in the demo or in the background, and only on a Wi-Fi whose
    /// subnet the address saved belongs to -- through one session for the whole look that keeps no cookies and
    /// follows no redirect, as every request to a television does. It is never woken.
    ///
    /// A link made in the demo is the demo's for good: let go of as the demo ends with a request of its own
    /// still to come back, what it does next looks at nothing on the LAN either.
    func tvLinkEnvironment() -> LinkEnvironment {
        let demosOwn = demo
        return LinkEnvironment(
            transport: { [weak self] host in self?.televisionTransport(host) ?? NoTelevision() },
            networkSignature: { [weak self] in self?.surroundings.networkSignature() ?? "" },
            sendPacket: { _, _ in },
            lanIsBlocked: { [weak self] host in
                guard let self, !demosOwn, !self.demo, self.surroundings.reachesTheLAN else { return false }
                return await LocalNetwork.access(probing: host) == .blocked
            },
            hostsNear: { [weak self] host in
                guard let self, !demosOwn, !self.demo, !self.inBackground, self.surroundings.reachesTheLAN else {
                    return []
                }
                return LocalNetwork.hostsToScan(near: host)
            },
            findRecorder: { _, _ in nil },
            findTelevision: { mac, hosts in
                await TVDiscovery.find(mac: mac, among: hosts, transport: URLSessionTransport.withoutCookies())
            })
    }

    /// How requests reach a television at `host`: the surroundings' way outside the demo; in it, the demo's
    /// television at its own address and nothing anywhere else. The demo's address is the demo's whichever way:
    /// once the demo has ended, a client made for it -- by a link of the demo's let go of with a request still
    /// to make -- reaches nothing, and never the LAN.
    func televisionTransport(_ host: String) -> any HTTPTransport {
        if RecorderAddress.same(host, DemoData.tvHost) { return demo ? theDemoTV() : NoTelevision() }
        return demo ? NoTelevision() : surroundings.tvTransport(host)
    }

    /// Where the registration with the television in play is kept: the surroundings' -- the Keychain, in the app
    /// -- outside the demo, and the demo's own in memory in it, made the first time it is asked for.
    func televisionCredentials() -> any TVCredentialStore {
        guard demo else { return surroundings.tvCredentials }
        let credentials = demoTVCredentials ?? MemoryTVCredentials()
        demoTVCredentials = credentials
        return credentials
    }

    /// The demo's television, made the first time the demo reaches its address and kept for as long as the demo
    /// lasts, because it holds what the reader has done to it: its registration and its reservations. The
    /// demo's search and the demo's link both reach this one.
    func theDemoTV() -> DemoTV {
        let television = demoTV ?? DemoData.television()
        demoTV = television
        return television
    }

    /// The address of the television in play: the one saved, or in the demo the demo's once it is added. Nil
    /// for none.
    private var savedTVHost: String? {
        guard !demo else { return demoTVHost }
        guard let host = defaults.string(forKey: DefaultsKey.tvHost), !host.isEmpty else { return nil }
        return host
    }

    /// The MAC saved with the television in play, or nil when none is in play or it gave none. The demo's is
    /// the invented one, which its television gives.
    private var savedTVMac: String? {
        guard savedTVHost != nil else { return nil }
        return demo ? DemoTV.mac : defaults.string(forKey: DefaultsKey.tvMac)
    }

    // MARK: - adding one

    /// Whether a television the scan found can be tapped to register it: while no television is in play, the
    /// demo's in the demo. With one the rows are listed and cannot be tapped -- a tap would register it again, or
    /// be refused for another (`registerTV`) -- and another is added after テレビを外す.
    var canAddAFoundTelevision: Bool { tv == nil }

    /// Whether a television the scan found is the one saved, which its row says: by the address the saved
    /// one's link is at, which follows it when it moves.
    func inUse(_ television: TVSighting) -> Bool {
        guard let tv else { return false }
        return RecorderAddress.same(television.host, tv.host)
    }

    /// What was found at an address the reader gave for the television: the package's answer, under the name
    /// the screens know it by.
    typealias TVFound = TVPresence

    /// Asks the device at `host` what it is, without a registration and without changing anything
    /// (`ScalarClient.presence`).
    ///
    /// Nothing answering may be the system keeping the app off the local network -- behind its question, or
    /// after a no -- which looks the same from here. So the permission is then looked at once, at that address,
    /// as the links look after silence (`Surroundings.localNetworkAccess`). When the look says the app is kept
    /// off, the sheet says so (`tvAddressTurnedAway`) in place of the address not answering, the permission is
    /// waited for as the links wait, and once it comes the address is asked again and that answer is the one
    /// handed back: the sheet goes on from it by itself, to the PIN on the panel of a television that is on.
    /// Never in the demo, where only the demo's television answers, at its own address.
    ///
    /// Closing the sheet ends the wait (`stopFindingTV`): what is handed back then is that nothing answered,
    /// and the address is not asked again, so nothing goes on to the registration -- no number is put on a panel
    /// -- after the sheet has gone, a permission given after it included.
    func findTV(at host: String) async -> TVFound {
        tvFindRun += 1
        let run = tvFindRun
        let client = ScalarClient(host: host, transport: televisionTransport(host),
                                  credentials: televisionCredentials())
        let found = await client.presence()
        guard found == .nothing, !demo, await surroundings.localNetworkAccess(host) == .blocked,
              run == tvFindRun else { return found }
        tvAddressTurnedAway = true
        let access = await surroundings.waitForLocalNetwork(host)
        guard run == tvFindRun else { return .nothing }
        tvAddressTurnedAway = false
        return access == .allowed ? await client.presence() : .nothing
    }

    /// The sheet that adds a television has closed: a wait for the permission at the address it was given ends
    /// with nothing answering, and the sheet's notice goes.
    func stopFindingTV() {
        tvFindRun += 1
        tvAddressTurnedAway = false
    }

    /// What became of a registration.
    enum TVRegistered: Equatable {
        /// The television wants its PIN, which it shows on its screen when it is showing a broadcast.
        case pinNeeded
        case registered
        case failed(String)
    }

    /// Registers with the television at `host`: with nothing at first, when it answers by putting its PIN on its
    /// screen, and then with the PIN the reader read there. The steps, and what each failure is said as, are
    /// the client's (`ScalarClient.enrol`). What is the app's is the client id, made once and kept, so that the
    /// PIN goes with the request that asked for it; and, once registered, saving the television and connecting
    /// to it on a link made afresh: an attach still out on the last one, with the last cookie, ends there.
    ///
    /// With a television saved, the registration is for that one: another, by the MAC saved with it, is
    /// refused before anything is asked of it, and what is saved and what waits for the one saved stay as they
    /// were. Another television takes its place only after テレビを外す, which asks about what waits for it.
    ///
    /// In the demo it is the demo's television's, kept in memory (`demoTVHost`, `televisionCredentials`), and
    /// nothing saved of the real one is written. A registration that went through after the demo began or ended
    /// under it is kept nowhere: it is the other side's.
    func registerTV(at host: String, pin: String?) async -> TVRegistered {
        let inDemo = demo
        let credentials = televisionCredentials()
        let clientID = credentials.load()?.clientID ?? tvClientID ?? "BDBridge:\(UUID().uuidString)"
        tvClientID = clientID
        let client = ScalarClient(host: host, transport: televisionTransport(host), credentials: credentials)
        switch await client.enrol(clientID: clientID, nickname: Self.tvNickname, pin: pin, expecting: savedTVMac) {
        case .pinNeeded:
            return .pinNeeded
        case .failed(let why):
            return .failed(why)
        case .registered(let mac):
            guard demo == inDemo else { return .failed(TVDriver.notConnected) }
            tvClientID = nil
            dropTVLink()
            if demo {
                demoTVHost = host
            } else {
                defaults.set(host, forKey: DefaultsKey.tvHost)
                if let mac {
                    defaults.set(mac, forKey: DefaultsKey.tvMac)
                } else {
                    defaults.removeObject(forKey: DefaultsKey.tvMac)
                }
            }
            forgetWhatWasTold()
            makeTVLink()
            await tv?.connect()
            return .registered
        }
    }

    /// What the runs with no screen told of the television (`TVTold`) is not held against the one in play
    /// from now on: a registration, or a television taken away, is a change, and the next run tells what it
    /// finds afresh. Their warning of reservations not yet at the television is taken away with it, where
    /// the app asks the system about notifications at all: it can end by telling the reader to register,
    /// which must not outlive the registration, and the reservations it names went unsent with a television
    /// taken away. When the stop told last is the registration, their notice of what became of the queue
    /// goes too: it is the one that asked for the registration whenever the warning did not.
    ///
    /// Not in the demo: what was told is of the real television, which the demo's registering or taking away
    /// changes nothing of.
    private func forgetWhatWasTold() {
        guard !demo else { return }
        let stop = defaults.data(forKey: DefaultsKey.tvTold)
            .flatMap { try? JSONDecoder().decode(TVTold.self, from: $0) }?.stop
        defaults.removeObject(forKey: DefaultsKey.tvTold)
        guard surroundings.asksAboutNotifications else { return }
        Notify.withdrawTelevisionNotYet()
        if stop == .registration { Notify.withdrawTelevisionQueue() }
    }

    /// The warning the runs with no screen left of reservations not yet at the television is taken away once
    /// a sending of the app's own, or a delete, leaves none of them waiting to go, and they are told of no
    /// more (`TVTold.afterTheScreensSent`): the next run with no screen, which would take it away otherwise,
    /// may come after their programmes have begun. Read from the phone's queue and not from the one on
    /// screen, which is empty when the queue cannot be read; a queue that cannot be read changes nothing.
    /// Not in the demo, whose queue is not the one the warning was about.
    func forgetTheWarningOnceSent() async {
        guard !demo, let saved = defaults.data(forKey: DefaultsKey.tvTold),
              let told = try? JSONDecoder().decode(TVTold.self, from: saved),
              let store, let waiting = try? await store.pendingReservations(),
              let after = told.afterTheScreensSent(waiting: waiting),
              let kept = try? JSONEncoder().encode(after) else { return }
        defaults.set(kept, forKey: DefaultsKey.tvTold)
        if surroundings.asksAboutNotifications { Notify.withdrawTelevisionNotYet() }
    }

    /// Takes the television away: its link, its address and its registration. What the television itself
    /// lists as registered is left; it can be removed from the list in the television's settings. What the
    /// runs with no screen told of it goes too (`forgetWhatWasTold`). In the demo, the demo's, in memory, and
    /// nothing of the real one's.
    func removeTV() {
        dropTVLink()
        televisionCredentials().remove()
        if demo {
            demoTVHost = nil
        } else {
            defaults.removeObject(forKey: DefaultsKey.tvHost)
            defaults.removeObject(forKey: DefaultsKey.tvMac)
        }
        forgetWhatWasTold()
        tvClientID = nil
    }

    /// How many reservations wait for the television, for the question before it is taken away. Read from
    /// the phone and not from the queue on screen, which is read only once the reservations tab has been
    /// opened. Nil when the phone's queue cannot be read, which is not none: the question then gives no
    /// count, where none would have it say nothing of reservations that 外す goes on to delete.
    func waitingForTheTelevision() async -> Int? {
        guard let store, let rows = try? await store.pendingReservations() else { return nil }
        return rows.filter { $0.target == .tv }.count
    }

    /// What the settings' 外す asks: what waits for the television goes with it, unsent, and then the
    /// television (`removeTV`). Whether it was taken away. `counted` is what the question said waits for
    /// it, as `waitingForTheTelevision` gave it.
    ///
    /// Nothing is done while the television is busy, which is asked again here as the first step. The
    /// button is held back by the same, but the question was up for as long as the reader took, and a
    /// sending begun meanwhile has a row in hand that it would go on to make, after the reader was told
    /// that it is not sent.
    ///
    /// Nor is anything done when what waits is no longer what the question counted. A sending that began
    /// and ended while the question was up is over by now, and may have made the very reservations the
    /// reader was told are deleted unsent: taken away then, the television would hold them where the app
    /// no longer shows it, and what the strip said of them would go with its host. The television stays
    /// and nothing is said; asked again, the question counts what waits by then. A question that could give
    /// no count is acted on only while there is still none to hold against it.
    ///
    /// When what waits cannot be deleted -- the phone's cache busy past its timeout, or not open -- the
    /// television stays and nothing is deleted, and its line says why. A television taken away over rows
    /// that stayed would leave them with nobody to send them and nobody to drop them once their programmes
    /// are over, which is what the question is there to prevent.
    ///
    /// The first step sees the app's own work only. A run with no screen sends through the same queue with a
    /// client of its own -- inferred for the action, as `deleteWaiting` says -- so the rest is done in the
    /// queue's turn (`PendingQueue.betweenFlushes`): a sending under way is over first, and one that made what
    /// was counted leaves a count that no longer holds. Taken away while such a run had its round out, the
    /// registration would go from under it, and the run would tell the reader to register a television that is
    /// no longer there.
    func takeTheTelevisionAway(counted: Int?) async -> Bool {
        guard !isBusy(for: .tv) else { return false }
        // The television the question was about: the demo begun or ended while this waits for the queue's turn
        // puts another in play, which the reader was not asked about.
        let asked = tvHost
        return await PendingQueue.betweenFlushes { @MainActor in
            guard self.tvHost === asked, await self.waitingForTheTelevision() == counted else { return false }
            guard let store = self.store, (try? await store.removePending(waitingFor: .tv)) != nil else {
                self.tvHost?.problem = AppModel.rowsNotTakenAway
                return false
            }
            self.removeTV()
            await self.loadPending()
            return true
        } ?? false
    }

    /// Said on the television's line when it was not taken away because what waits for it could not be
    /// deleted.
    static let rowsNotTakenAway = "送信待ちの予約を削除できなかったため、テレビを外していません。"
        + "少し待ってから、もう一度お試しください。"
}
