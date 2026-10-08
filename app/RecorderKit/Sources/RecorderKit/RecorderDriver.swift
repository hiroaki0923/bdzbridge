import Foundation

/// What is particular to a BDZ recorder in a link: it is woken by a magic packet and waited for, found at another
/// address by the MAC at the end of its UDN, recognised by that UDN, and read on every attach for its firmware,
/// its MAC, its free space and the disk in its USB slot, which are only shown or kept and must not fail the
/// attach; a USB disk known is not let go of on one answer of none (`learnTheSlot`). The runs with no screen,
/// which have no link, make their attempt here too (`reachWithNoScreen`, `isTheOneKnown`).
///
/// What is asked of the recorder's reservations after its attach is here as well, as a television's is its
/// driver's: reading them (`reservations`, `refreshReservations`), sending what waits for the recorder in the
/// phone's queue (`sendWhatWaits`, `resend`) and deleting one (`cancel`) -- the steps, and what each hands back
/// for the app to keep. A change, a reservation and the clash check are still the app's (`AppModel`).
@MainActor
public final class RecorderDriver: LinkDriver {
    /// The link holds the driver, so weak; it is set once, as the link is made. Each operation asked of the
    /// driver goes through on it, written on the parts of an operation the link carries (`DeviceLink.run`,
    /// `underALine`, `say`): the reads of the reservations, the sending of what waits and a waiting row sent
    /// again, a delete, and the slot's settling and what it came to. The recorder's other operations are still
    /// the app's, and will be asked of this the same way.
    public weak var link: DeviceLink?
    /// Written on each reservation that was waiting when another recorder took the place of the one it was made
    /// for (`GuideStore.claim`): `heldForAnotherRecorder`, unless a test gives a sentence of its own.
    private let heldWith: String
    /// How long the screens wait for the recorder to answer after the packet, and how often they ask meanwhile.
    private let wakingLimit: TimeInterval
    private let wakingInterval: Duration
    /// How long a client waits before sending again what the recorder answered 503 (`RecorderClient`).
    private let busyRetryDelay: ClosedRange<Double>

    /// The reason written on the rows held for another recorder, the waking's limit and interval, and the pause
    /// before a 503 is sent again, are given only by the tests, which have no seconds to wait.
    public init(holdingTheQueueWith reason: String = RecorderDriver.heldForAnotherRecorder,
                wakingLimit: TimeInterval = Waking.screenLimit,
                wakingInterval: Duration = .seconds(1), busyRetryDelay: ClosedRange<Double> = 0.5...1) {
        heldWith = reason
        self.wakingLimit = wakingLimit
        self.wakingInterval = wakingInterval
        self.busyRetryDelay = busyRetryDelay
    }

    /// Short: a recorder that has left the network says nothing rather than refuse, and a patient timeout is
    /// half a minute of silence before anything is done about it.
    public var probeTimeout: TimeInterval { RecorderClient.probeTimeout }

    public var noAnswerLine: String { RecorderError.transport("no answer").explanation }

    /// Every one, whatever the session says: a recorder that answered without saying which it is is not
    /// connected, is read all the same, and its silence is to lose it and be said like any other.
    public func takesSilenceOnARead(_ link: DeviceLink) -> Bool { true }

    public func makeClient(for link: DeviceLink) -> any LinkClient {
        RecorderClient(host: link.host, transport: link.environment.transport(link.host),
                       busyRetryDelay: busyRetryDelay, slotSettling: link.environment.slotSettling)
    }

    /// Once a MAC is known, which is what a magic packet needs. The address cannot be guessed and iOS will not
    /// read the ARP table.
    public func canWake(_ link: DeviceLink) -> Bool { link.session.canWake }

    public func sendPacket(_ link: DeviceLink) {
        guard let mac = link.session.mac else { return }
        link.environment.sendPacket(mac, link.host)
    }

    // MARK: - attaching

    /// Reads what the recorder says about itself. Only the description decides whether the app is connected. The
    /// firmware, the MAC, the free space and the disk in the USB slot are read too, but another model may refuse
    /// one or answer in a shape of its own, and that must not fail the attach: what cannot be read is left
    /// unknown. Silence still ends it. What waits is sent before the slot is read, and an attach that met silence
    /// in either has not reached anything to show.
    ///
    /// `quiet` keeps a failure off the screen, for a probe about to be answered with a magic packet.
    public func attach(_ link: DeviceLink, client: any LinkClient, what: String? = "接続中",
                       timeout: TimeInterval? = nil, quiet: Bool = false) async -> Bool {
        guard let client = client as? RecorderClient else { return false }
        let owner = link.owner
        // A line of its own, and only that one taken away afterwards: this can run inside the waking.
        var activity: Activities.Token?
        if let what { activity = owner?.beginActivity(what) }
        defer { if let activity { owner?.endActivity(activity) } }
        do {
            // A cache that is another recorder's and could not be made over to this one is no recorder to
            // connect to: the app would go on over the other's guide and texts.
            guard await settle(link, whoAnswered: try await client.describe(timeout: timeout)) else {
                owner?.cacheCouldNotBeMadeOver()
                return false
            }
            // The runs with no screen read the address from what the phone keeps.
            owner?.keepAddress(link.host)
            link.session.learned(firmware: try await RecorderError.silenceOnly { try await client.firmwareVersion() }
                ?? "")
            // Kept for waking it later, and read every time: on iOS the recorder is the only place it comes from.
            if let settings = try await RecorderError.silenceOnly({ try await client.networkSettings() }) {
                owner?.keepMAC(settings.mac)
            }
            link.session.learned(storage: try await Self.storage(of: client))
            // From the moment it answers -- a waking above all, after which the slot answers none with the disk in
            // it -- a disk known is not to be had until the slot answers it: in the same turn as the answer, before
            // anything waiting is sent, so that nothing that names the slot goes in between.
            let diskKnown = await Self.knownUSBDisk(link) != nil
            link.session.answered()
            if diskKnown { link.session.answeredWithAUSBDiskKnown() }
            owner?.problem = nil
            await owner?.sendWhatWaits()
            // The recorder can go quiet in the middle of sending the queue, which leaves the app offline like any
            // other silence; a connect that ended there has not reached anything to show.
            guard !link.session.unreachable else { return false }
            // After what waits, so that a slot slow to answer, or silent, does not hold back a reservation, in a
            // home with no USB disk as much as in one with. Its silence still ends the attach.
            await Self.learnTheSlot(try await Self.usbDisk(of: client), link, client: client)
            link.session.attached()
            return true
        } catch {
            let deviceError = error as? any DeviceError
            // Nothing answered, so the app is not connected; nor when the address is not an address. Anything
            // else answered, and what is known of the recorder stands (`SessionState.attachFailed`).
            link.session.attachFailed(deviceError?.failure)
            // Quiet keeps only silence off the screen, since only silence is answered with a magic packet.
            if !quiet || !link.session.unreachable {
                owner?.problem = deviceError?.explanation ?? String(describing: error)
            }
            return false
        }
    }

    /// A recorder has said who it is, which decides what the app keeps of the one before it: the same recorder
    /// keeps everything wherever it answers, and another one gets nothing that was the last one's. Asked at every
    /// attach, before anything is read from the recorder or sent to it. False when the cache is another's and
    /// could not be made over: the caller does not go on.
    private func settle(_ link: DeviceLink, whoAnswered recorder: RecorderDescription) async -> Bool {
        let owner = link.owner
        let wasConnected = link.session.connected
        let inMemory = link.session.described(recorder)
        if inMemory == .another {
            owner?.anotherDeviceDescribedItself(wasConnected: wasConnected)
            // The disk the slot was to be read again for was the last one's.
            link.endTheReadLeftForLater()
        }
        // The demo's cache is a file of its own, made for the invented recorder and deleted with it.
        guard let owner, !owner.isDemo, let store = owner.cache else { return true }
        // What the session knows goes with it: a cache with no owner written is the last recorder's when the lists
        // were.
        let lastWasAnother = inMemory == .another
        let onDisk: Recognition
        do {
            onDisk = try await store.claim(for: recorder, holdingTheQueueWith: heldWith,
                                           knownToBeAnother: lastWasAnother)
        } catch {
            // The cache could not be written to. For the recorder it is of, or the first heard from, that costs
            // nothing. Another one's it stays, and one that cannot even be read is nobody's to go on over.
            guard let asked = try? await store.recognises(recorder),
                  asked == .same || (asked == .first && !lastWasAnother) else { return false }
            onDisk = asked
        }
        guard inMemory == .another || onDisk == .another else { return true }
        if let mac = link.session.mac, !recorder.hasMAC(mac) { owner.forgetMac() }
        guard onDisk == .another else { return true }
        // A USB disk known goes where the cache goes, from memory as well: one the session still holds was learned
        // from a recorder that did not say who it is, which the cache was taken to be of.
        link.endTheReadLeftForLater()
        link.session.learned(usbDisk: nil)
        await owner.cacheMadeOver()
        return true
    }

    /// The free space as the screens show it, or nil when the recorder will not say. A disk of no size counts as
    /// not saying: the screens would show it as a full disk. Throws only silence.
    public static func storage(of client: RecorderClient) async throws -> (free: Int, total: Int)? {
        guard let capacity = try await RecorderError.silenceOnly({ try await client.recordDestinationInfo() }),
              capacity.totalBytes > 0 else { return nil }
        return (capacity.freeBytes, capacity.totalBytes)
    }

    /// The disk in the recorder's USB slot, when the recorder has registered one; nil when the slot is refused, its
    /// answer cannot be read or describes no disk, or the disk it describes was never registered. The one place
    /// that decides whether a USB disk is known, for the screens and for the overnight run alike, so that no
    /// answer from a recorder that never had one draws anything. Throws only silence.
    ///
    /// What the slot answers with the disk unplugged has not been seen. A registered disk described as not
    /// mounted is kept, and offered nowhere (`RecorderDisk.takesRecordings`).
    public nonisolated static func usbDisk(of client: RecorderClient) async throws -> RecorderDisk? {
        try await RecorderError.silenceOnly { try await registeredDisk(of: client) } ?? nil
    }

    /// The slot's answer by the same rule, every failure thrown: for the read again, to which a recorder busy with
    /// another client's request has said no more of the slot than silence has.
    private nonisolated static func registeredDisk(of client: RecorderClient) async throws -> RecorderDisk? {
        guard let disk = try await client.disk(RecorderDisk.usbID), !disk.registered.isEmpty else { return nil }
        return disk
    }

    /// How long after an attach found the slot answering no disk, while one was known, the slot is read again.
    /// Right after a waking, a BDZ-FBT4100 that had described itself about eight seconds after the packet answered
    /// the slot as if no disk were registered; timed once with the slot read every five seconds, it answered the disk
    /// by the read five seconds after it first answered at all. Thirty seconds leaves room for a slower disk while
    /// a disk that is really gone is let go of soon. Handed to the link with its surroundings
    /// (`LinkEnvironment.slotReadAgainAfter`), where a test gives less.
    public nonisolated static let slotReadAgainAfter: Duration = .seconds(30)

    /// What an attach makes of the slot's answer. A disk answered, the one known or another, is taken at once.
    /// No disk answered while one is known -- by this run, or kept with the cache by an earlier one -- does not
    /// let it go, since the waking attach is the common one: the disk known stays, shown as it was read and waited
    /// for before anything names it (`SessionState.usbDiskUnanswered`), and the slot is read once more a while
    /// later (`readTheSlotAgain`), which lets it go if it answers no disk too. With no disk known, no disk is what
    /// there is, and nothing is left for later. Whatever was left for later by an earlier attach is over: this
    /// answer is newer.
    private static func learnTheSlot(_ answered: RecorderDisk?, _ link: DeviceLink, client: RecorderClient) async {
        link.endTheReadLeftForLater()
        let known = answered == nil ? await knownUSBDisk(link) : nil
        if let known {
            link.session.learned(usbDisk: known)
            link.readLater(after: link.environment.slotReadAgainAfter) { link in
                await readTheSlotAgain(link, client: client)
            }
        } else {
            await keep(answered, link)
        }
    }

    /// The USB disk known before the slot's answer: the session's, or at the first attach after a launch, which
    /// has none yet, the one kept with the cache.
    private static func knownUSBDisk(_ link: DeviceLink) async -> RecorderDisk? {
        if let known = link.session.usbDisk { return known }
        return try? await link.owner?.cache?.knownUSBDisk()
    }

    /// The slot read once more, a while after an attach found no disk where one was known: one request, on that
    /// attach's client, and only while the link still asks through it and the recorder has not been given up
    /// on since. Only an answer settles it: a disk answered is taken, and no disk answered again, or a refusal,
    /// lets the one known go. Silence, and a recorder still busy with another client's request after the client's
    /// tries, change nothing, the disk known and the link alike: the next attach reads the slot anyway, and the
    /// disk is waited for before anything names it meanwhile (`settleTheSlot`). An answer that comes back after the
    /// read was ended is left, since whatever ended it knows better; so is one that comes back once the link asks
    /// through another client, a connect under way whose attach reads the slot itself.
    private static func readTheSlotAgain(_ link: DeviceLink, client: RecorderClient) async {
        guard link.client === client, !link.offline else { return }
        let answered: RecorderDisk?
        do {
            answered = try await registeredDisk(of: client)
        } catch let error as any DeviceError where error.failure == .silent || error.failure == .busy {
            return
        } catch {
            // A refusal, or an answer that cannot be read, is no disk, as at an attach (`usbDisk`).
            answered = nil
        }
        guard !Task.isCancelled, link.client === client else { return }
        await keep(answered, link)
    }

    /// Puts `disk`, as the slot answered it, down as the USB disk known, in the session and with the cache, which
    /// keeps it for the next launch; nothing is waited for once the slot has answered. The cache is written only
    /// when the session held something else, so an attach answered as before writes nothing; one that cannot be
    /// written costs only that launch's first waking.
    private static func keep(_ disk: RecorderDisk?, _ link: DeviceLink) async {
        if disk != link.session.usbDisk { try? await link.owner?.cache?.keep(knownUSBDisk: disk) }
        link.session.slotAnswered(disk)
    }

    // MARK: - before something that names the slot is sent

    /// The slot read until it answers a disk: at once, and while it answers none, again every `settling.interval`
    /// until `settling.limit` has gone by -- six reads in about ten seconds, with the app's settling. A disk and
    /// none are what `usbDisk` reads them as, a refusal and a recorder still busy after the client's tries among
    /// none; silence ends it there. Nothing is kept of what it read: that is for whoever asked. The one place the
    /// slot is waited for, by the screens (`settleTheSlot`) and by the queue's round (`RecorderClient.send`).
    public nonisolated static func settle(_ client: RecorderClient, by settling: SlotSettling) async -> SlotSettled {
        for read in 1...settling.reads {
            if Task.isCancelled { return .cancelled }
            do {
                if let disk = try await usbDisk(of: client) { return .answered(disk) }
            } catch {
                return .silent
            }
            guard read < settling.reads else { break }
            do {
                try await Task.sleep(for: settling.interval)
            } catch {
                return .cancelled
            }
        }
        return .noDisk
    }

    /// What a screen says while it waits for the slot to answer before something that names it is sent.
    public static let settlingLine = "録画先のディスクを確かめています"

    /// Before a screen sends something that names `destination` -- a reservation, a change, a keyword condition, a
    /// clash check -- once the recorder has been made sure of. Nothing is sent to the slot on the strength of a disk
    /// it has not answered since the recorder last answered: from the moment an attach finds the recorder answering
    /// with a disk known -- what waits being sent, the slot still to be read -- until the slot answers it
    /// (`SessionState.usbDiskUnanswered`), the slot is settled first (`settle`), under a line of its own on the
    /// host's screen (`settlingLine`, `SessionState.settlingTheSlot`). That covers the whole time after a wake: the
    /// attach's own read, the read again half a minute later, and a read again that met silence or a busy recorder
    /// and left the disk kept with nothing more to read.
    ///
    /// A disk answered is taken as the read again takes one, in the session and with the cache, and the read is
    /// ended -- unless the link asks through another client by then, whose attach reads the slot itself. None
    /// throughout leaves the disk known and the read as they were, still waited for, and what to say of it is the
    /// caller's, which knows what else its screen offers. Silence loses the recorder and says so, as a read that
    /// meets it does; nothing has been sent. What it came to is handed back. Nil, with nothing asked, for any other
    /// destination, and for a disk the slot has answered since the recorder last answered: in a home with no USB
    /// disk nothing is added.
    public func settleTheSlot(for destination: String) async -> SlotSettled? {
        guard destination == RecorderDisk.usbID, let link, link.session.usbDiskUnanswered, !link.offline,
              let client = link.client as? RecorderClient else { return nil }
        let owner = link.owner
        link.session.beganSettlingTheSlot()
        let line = owner?.beginActivity(Self.settlingLine)
        defer {
            link.session.endedSettlingTheSlot()
            if let line { owner?.endActivity(line) }
        }
        let settled = await Self.settle(client, by: link.environment.slotSettling)
        switch settled {
        case .answered(let disk):
            guard link.client === client else { break }
            link.endTheReadLeftForLater()
            await Self.keep(disk, link)
        case .silent:
            _ = link.say(.silentOnARead(sentence: noAnswerLine))
        case .noDisk, .cancelled:
            break
        }
        return settled
    }

    /// Why something that names a disk of the recorder's is not sent once the slot has been waited for
    /// (`withholds`).
    public enum Withheld: Sendable, Equatable {
        /// The slot answered no disk each time, or a disk that takes no recordings: the disk cannot be had now.
        /// The caller says so, by what its sheet has left to offer.
        case noDisk
        /// The recorder fell silent, which the link has said and lost it for. Nothing was sent.
        case silence
        /// Whoever waited gave up first. Nothing is said.
        case givenUp
    }

    /// Before something that names `disk` is sent, once the recorder has been made sure of: while the slot has not
    /// answered the USB disk known since the recorder last answered -- from the attach on, a waking one above all --
    /// the slot is waited for (`settleTheSlot`). Nil when it may go: nothing had to be waited for -- another disk, a
    /// disk answered, a home with no USB disk, where nothing is asked -- or the slot answered a disk that is
    /// offered, which is taken. Otherwise why not, with a disk not had put down in the session for the sheets
    /// (`SessionState.diskNotHad`): a disk answered that takes no recordings is not had either.
    public func withholds(_ disk: String) async -> Withheld? {
        guard let link else { return nil }
        switch await settleTheSlot(for: disk) {
        case nil:
            return nil
        case .answered?:
            guard RecorderDisk.offers(disk, with: link.session.usbDisk) else { break }
            return nil
        case .noDisk?:
            break
        case .silent?:
            return .silence
        case .cancelled?:
            return .givenUp
        }
        link.session.slotHadNoDisk(for: disk)
        return .noDisk
    }

    /// A request that can name a disk of the recorder's begins -- a reservation, a change, a condition, a clash
    /// check -- whichever disk it names: the disk the last one found not to be had is forgotten
    /// (`SessionState.diskNotHad`).
    public func clearTheDiskNotHad() {
        link?.session.requestNamingADiskBegan()
    }

    // MARK: - waking

    /// The magic packet, then waiting for the recorder to answer; a BDZ-FBT4100 is back in about ten seconds.
    /// The wait goes on in a task of its own whatever becomes of the caller: a pull on the list abandoned half
    /// way must not leave the app given up on a recorder that is coming up.
    public func wakeAndAttach(_ link: DeviceLink, client: any LinkClient) async -> Bool {
        guard link.session.unreachable, link.session.mac != nil else { return false }
        sendPacket(link)   // again: the attempt sends one too, and a second costs nothing
        let owner = link.owner
        // Nothing is wrong yet, so nothing on screen should say there is.
        owner?.problem = nil
        link.session.beginWaking()
        let activity = owner?.beginActivity(Self.wakingLine(0))
        defer {
            link.session.endWaking()
            if let activity { owner?.endActivity(activity) }
        }
        let limit = wakingLimit, interval = wakingInterval
        let outcome = await Task {
            await Waking.waitForAnswer(from: client, limit: limit, interval: interval,
                                       resend: { @MainActor in self.sendPacket(link) },
                                       waited: { @MainActor seconds in
                                           guard let activity else { return }
                                           owner?.updateActivity(activity, to: Self.wakingLine(seconds))
                                       })
        }.value
        if outcome == .answered {
            return await attach(link, client: client, what: "接続中", timeout: probeTimeout, quiet: false)
        }
        owner?.problem = "レコーダーが応答しません。電源とネットワーク接続を確認してください。"
        return false
    }

    private static func wakingLine(_ seconds: Int) -> String {
        "レコーダーを起動しています（\(seconds) 秒）"
    }

    // MARK: - a recorder that is not where it was

    /// Looks for the recorder at another address, once, after waking it where it was came to nothing: its
    /// address is a DHCP lease, which the router hands out again after a power cut. It is told from any other by
    /// the MAC kept for waking it, the tail of its UDN. When found, the address and where the MAC was read move
    /// with it, and it is attached there with a client of its own.
    public func findElsewhere(_ link: DeviceLink) async -> DeviceFailure? {
        guard let moved = await findMoved(link) else { return .silent }
        link.host = moved.host
        // It is the recorder the MAC was read from, which its UDN has just said.
        link.owner?.macWasReadAt(moved.host)
        let found = makeClient(for: link)
        link.client = found
        return await attach(link, client: found, what: "接続中", timeout: probeTimeout, quiet: false)
            ? nil : link.whyNotAttached
    }

    private func findMoved(_ link: DeviceLink) async -> RecorderDescription? {
        guard let mac = link.session.mac, macWasReadHere(link) else { return nil }
        let hosts = link.environment.hostsNear(link.host)
        guard !hosts.isEmpty else { return nil }
        let owner = link.owner
        // The waking's failure is not the last word yet: it is put back if the search finds nothing either.
        let failure = owner?.problem
        owner?.problem = nil
        link.session.beginWaking()
        let activity = owner?.beginActivity("レコーダーを探しています")
        defer {
            link.session.endWaking()
            if let activity { owner?.endActivity(activity) }
        }
        let moved = await link.environment.findRecorder(mac, hosts)
        if moved == nil { owner?.problem = failure }
        return moved
    }

    /// Whether the MAC is the one the recorder at this address reported, or nobody knows where it was read.
    /// After the reader types another recorder's address the MAC is still the old one's until the new one
    /// answers, and the search would quietly go back to the recorder just left.
    private func macWasReadHere(_ link: DeviceLink) -> Bool {
        guard let readAt = link.owner?.macReadAt else { return true }
        return readAt == link.host
    }

    // MARK: - the reservations

    /// The line on screen while the reservations are read.
    public static let readingLine = "予約一覧を取得中"

    /// What the recorder is set to record, read now: nil when it could not be read, and the host's line says
    /// why. With no recorder's client, or the recorder silent at the last ask, nothing is sent and nothing is
    /// said: every screen asks this as it appears, and a recorder known to be away costs no timeout.
    ///
    /// One operation through the link (`DeviceLink.run`): under a line of its own, the recorder made sure of
    /// first -- inside a connect, which has just heard it, at once -- and a read that goes through clears the
    /// line of what went wrong. It is sent on the client `run` hands over, the one in hand as the check was
    /// asked. A read that is a step of something else -- before a delete or a change, after a sending -- has
    /// a line of its own all the same, as it is today; a later change reads those under the operation's line.
    public func reservations() async -> [Reservation]? {
        guard let link, link.client is RecorderClient, !link.session.unreachable else { return nil }
        let read = await link.run(line: Self.readingLine) { client in
            try await (client as? RecorderClient)?.reservations()
        }
        if case .success(let list) = read { return list }
        return nil
    }

    /// What pulling the list down asks for: the list read again and what waits sent, or a connect when the
    /// recorder is not connected, which does both once it has answered (`attach`, `LinkHost.reached`), and nil
    /// -- what a connect that got nowhere has to say is on its line. Not connected, rather than offline: a
    /// recorder that answered the last connect without saying which it is, busy with somebody else as it was
    /// asked, is not offline, and the queue does not go to one (`sendWhatWaits`). Otherwise the newest list
    /// read, nil when none was, and what the sending came to, nil when none ran.
    ///
    /// The list is read before what waits is sent, and again after a sending that made something; the read
    /// after is the one handed back when there is one, since the one before would put the older list over it.
    /// The sending is this driver's own, not asked through the host as an attach asks it. As it is today; a
    /// later change sends first and reads once, as the television's pull-down does.
    public func refreshReservations() async -> (list: [Reservation]?, round: PendingQueue.Outcome?)? {
        guard let link else { return nil }
        guard link.session.connected else {
            await link.connect()
            return nil
        }
        let read = await reservations()
        let (round, after) = await sendWhatWaits()
        return (after ?? read, round)
    }

    // MARK: - what waits in the queue

    /// The line on screen while what waits for the recorder is sent.
    public static let sendingLine = "送信待ちの予約を登録中"

    /// Written on each reservation that was waiting when another recorder took the place of the one it was
    /// made for, which holds it as a refusal does (`PendingQueue.flush`). How to send it again is said by the
    /// row's swipe, the programme's sheet and the reservations screen's footer. Stored on the phone's rows and
    /// counted by these letters (`heldBack`): never to be reworded.
    public nonisolated static let heldForAnotherRecorder = "別のレコーダーに切り替わったため、送らずに残しています。"
        + "「もう一度送る」を選ぶと、いまのレコーダーに送ります。"

    /// What the strip says first after a sending, for as long as any row waits held for another recorder:
    /// how many, counted from the rows by the sentence written on them (`heldForAnotherRecorder`), since the
    /// attach that held them need not have got as far as a sending. Nil when none is.
    public nonisolated static func heldBack(in pending: [PendingReservation]) -> String? {
        let held = pending.filter { $0.problem == heldForAnotherRecorder }.count
        return held == 0 ? nil
            : "別のレコーダーに切り替わったため、送信待ちの予約 \(held) 件は送らずに残しています。予約タブから送り直せます"
    }

    /// Sends what waits in the phone's queue for the recorder, by the rules in `PendingQueue` -- the same ones
    /// the overnight run uses. What the round came to, nil when none ran, and the list read after it, nil when
    /// none was: read only when something was sent, which is what puts the new reservation on screen. Asked by
    /// the host whenever the recorder has just answered, which means from inside a connect, and here when the
    /// list is pulled down or a row sent again: nothing here waits for the app's start.
    ///
    /// Only to a recorder that has described itself: whatever answers a connect some other way -- a 503, or as
    /// something that is no recorder -- must not be handed what was waiting for the last recorder. And only
    /// when a row waits for the recorder. What waits for the television is its own driver's to send
    /// (`TVDriver.sendWhatWaits`): with nothing but such rows the recorder's line would go up for a flush that
    /// sends nothing, and that flush would wait its turn behind a television's sending that is out. Otherwise
    /// nothing is asked and nothing said. The host is told the queue may have changed as it is looked at and
    /// after the round (`LinkHost.queueWritten`), so that the screens read it again.
    ///
    /// The rows go under a line of their own, on the client in hand as this was asked. What had not been sent
    /// when the recorder fell silent stays queued for the next answer, and the recorder is lost as for any
    /// silence, with nothing said: as it is today; a later change says on the line that what was out may
    /// have arrived. What became of the round is the host's to say.
    public func sendWhatWaits() async -> (round: PendingQueue.Outcome?, list: [Reservation]?) {
        guard let link, let client = link.client as? RecorderClient, let store = link.owner?.cache,
              link.session.connected else { return (nil, nil) }
        await link.owner?.queueWritten()
        let rows = (try? await store.pendingReservations()) ?? []
        guard rows.contains(where: { $0.target == RecorderClient.slot }), !link.session.unreachable else {
            return (nil, nil)
        }
        let round = await link.underALine(Self.sendingLine) { _ in
            await PendingQueue.flush(client: client, store: store)
        }
        if round.interrupted { link.lost() }
        await link.owner?.queueWritten()
        let list = round.sent.isEmpty ? nil : await reservations()
        return (round, list)
    }

    /// Sends a row waiting for the recorder again, as the reader asked on that row: a refused row is not sent
    /// again by itself (`PendingQueue.flush`), but the reason can go away -- a channel subscribed to since, an
    /// antenna put right -- and only the reader knows when it has. What the round came to, nil when none ran,
    /// and the list read after it, as `sendWhatWaits` hands them back.
    ///
    /// A row that is not the recorder's is refused before anything else: nothing is read, sent, written or said
    /// for it. It is another device's to send again. With the link or the cache gone any row is refused the
    /// same way.
    ///
    /// The row's reason is taken off, so that it goes with the rest from now on, and the host is told, so that
    /// the screens show it without one before the recorder is made sure of. Then nothing more while the recorder
    /// is known to be away, or the check before an operation says no: the row goes the next time the recorder
    /// answers. There, and not connected -- a recorder that answered the last connect without saying which it
    /// is -- a connect asks it again, and its attach sends what waits if it describes itself. Connected, what
    /// waits is sent now.
    ///
    /// Everything that waits for the recorder is sent, not this row alone, and nothing is handed back of the
    /// row itself, the strip saying what was sent: as it is today; a later change sends the one row and says
    /// what it came to, as the television's driver does.
    public func resend(_ waiting: PendingReservation) async
        -> (round: PendingQueue.Outcome?, list: [Reservation]?, came: Reserved?) {
        guard waiting.target == RecorderClient.slot, let link, let store = link.owner?.cache else {
            return (nil, nil, nil)
        }
        try? await store.setPendingProblem(waiting.id, nil)
        await link.owner?.queueWritten()
        guard !link.offline, await link.ensureUp() else { return (nil, nil, nil) }
        guard link.session.connected else {
            await link.connect()
            return (nil, nil, nil)
        }
        let (round, list) = await sendWhatWaits()
        return (round, list, nil)
    }

    // MARK: - deleting one

    /// The line on screen while a reservation is deleted.
    public static let deletingLine = "予約を削除中"

    /// Said when a reservation to delete or to change is not in the list just read: the recorder no longer holds
    /// it, and the list on screen is the one just read.
    public static let alreadyDeleted = "この予約はすでにレコーダーから削除されていました。一覧を更新しました。"

    /// Said when the recorder answers a delete or a change that it holds no such reservation (804 or 820) though
    /// the list just read had one: that list was itself out of date, and it has been read again.
    public static let renumbered = "レコーダー側で予約が更新されていました。一覧を更新したので、もう一度お試しください。"

    /// Said when a write met silence. Whether it arrived is not known, which is exactly why it is not sent
    /// again, and what the list says once the recorder answers is the only way to find out.
    public nonisolated static let mayHaveArrived = "送信の途中でレコーダーの応答がなくなりました。届いている場合もあるため、"
        + "送り直していません。再接続してから一覧で確かめてください。"

    /// Deletes one of the recorder's reservations, as the recorder holds it now rather than by the id the app
    /// happens to hold. Whether it was deleted, and the freshest list read on the way for the caller to keep,
    /// nil when none was read.
    ///
    /// The recorder rewrites the ids of the reservations its own automatic recording made, the whole block of
    /// them at once, when it works through the guide again (`Reservation.createdByRecorder`): an id read a few
    /// hours ago can be dead while the row still looks right, and deleting it answers 804. So the list is read
    /// again first (`reservations`) and this reservation found in it: by its id while that stands, and otherwise
    /// by its channel and the moment it starts (`current`).
    ///
    /// A reservation that is not the recorder's is refused before anything else: nothing is read, sent or said
    /// for it. It is another device's to delete. With the link gone any reservation is refused the same way, and
    /// with no recorder's client in hand nothing is said either. Known to be away, nothing is sent -- the list
    /// has to be read first, and nothing can be read -- and the host says that the app is not connected. A read
    /// that meets silence ends it there, under the read's sentence. A reservation not in the list has gone, and
    /// the line says so.
    ///
    /// The list it is looked for in is the one the read handed back, or when the read failed some other way,
    /// the list the caller holds as it stands after the read (`inHand`), which a pull-down may have replaced
    /// meanwhile: a read turned down leaves the recorder there, and the delete goes out from that list. As it is
    /// today; a later change sends nothing after a read that failed, and takes `inHand` away.
    ///
    /// The delete is sent once, under a line of its own, on the client the link holds after the read: a connect
    /// made while the read was out has a client of its own, and one kept from before would send beside it, or to
    /// an address the recorder has left. The line comes down before anything is read after it. Silence there may
    /// be a delete that arrived: nothing is sent after it, the recorder is lost, and the line says it may have
    /// arrived. 804 or 820 -- the list just read was itself out of date, which is what happens when reading it
    /// failed -- has the list read again first, since a read that goes through clears the line, and then says
    /// so. Any other failure is said on the line by the link (`DeviceLink.say`): a refusal in the recorder's
    /// words, the recorder kept and nothing read after it, and an error that is no device's as Swift describes it.
    ///
    /// After a delete that went through the list is read once more, and the row is taken out of whatever comes
    /// back -- that read, the one before it, or the caller's list when neither went through: a recorder a moment
    /// behind itself must not bring it back, and the delete counts though that read fails.
    public func cancel(_ reservation: Reservation, inHand: @MainActor () -> [Reservation]) async
        -> (deleted: Bool, list: [Reservation]?) {
        guard reservation.device == .recorder, let link, link.client is RecorderClient else { return (false, nil) }
        let owner = link.owner
        guard !link.offline else {
            owner?.sayNotConnected()
            return (false, nil)
        }
        let read = await reservations()
        // The read has said why.
        guard !link.offline else { return (false, read) }
        guard let target = (read ?? inHand()).current(reservation) else {
            owner?.problem = Self.alreadyDeleted
            return (false, read)
        }
        guard let client = link.client as? RecorderClient else { return (false, read) }
        let failure = await link.underALine(Self.deletingLine) { _ -> (any Error)? in
            do {
                try await client.deleteReservation(id: target.id)
                return nil
            } catch {
                return error
            }
        }
        guard let failure else {
            owner?.problem = nil
            let after = await reservations()
            return (true, (after ?? read ?? inHand()).filter { $0.id != target.id })
        }
        if (failure as? any DeviceError)?.failure == .unknownItem {
            let newer = await reservations()
            owner?.problem = Self.renumbered
            return (false, newer ?? read)
        }
        _ = link.say(OperationFailure(failure, sending: Self.mayHaveArrived))
        return (false, read)
    }

    // MARK: - the check before an operation

    public func check(_ link: DeviceLink, client: any LinkClient) async -> (failure: DeviceFailure?, stranger: Bool) {
        guard let client = client as? RecorderClient else { return (.unexpected("not a recorder's client"), false) }
        do {
            let answering = try await client.describe(timeout: probeTimeout)
            return (nil, link.session.recognises(answering) == .another)
        } catch {
            return ((error as? any DeviceError)?.failure ?? .unexpected(String(describing: error)), false)
        }
    }

    // MARK: - the runs with no screen

    /// One attempt at the recorder for a run with no screen -- the overnight refresh and the Shortcuts action,
    /// which have no link -- in the order `Reach.run` keeps. Unlike the screens it waits for a recorder that
    /// answered the first ask with an error too -- one still starting up may answer anything, and nobody is
    /// watching the wait -- except at an address that is not one, where nothing could be asked. There is no
    /// screen to explain the local network permission on, and nowhere else is looked.
    ///
    /// `sendPacket` sends the magic packet and says whether one went out: nothing here puts one on the LAN by
    /// itself. Without one there is nothing coming up to wait for. The wait is the screens' (`Waking`), with the
    /// longer limit and the next packet timed from the first; `limit` and `interval` are given only by the tests.
    public nonisolated static func reachWithNoScreen(_ client: RecorderClient,
                                                     limit: TimeInterval = Waking.backgroundLimit,
                                                     interval: Duration = .seconds(1),
                                                     sendPacket: @escaping @Sendable () -> Bool) async -> Bool {
        // Both are set as the packet goes, which is the first step.
        var wentAt = Date()
        var went = false
        let outcome = await Reach.run(Reach.Steps(
            sendPacket: {
                wentAt = Date()
                went = sendPacket()
            },
            probe: {
                do {
                    try await client.describe(timeout: RecorderClient.probeTimeout)
                    return nil
                } catch let error as any DeviceError {
                    return error.failure
                } catch {
                    return .unexpected(String(describing: error))
                }
            },
            wake: {
                guard went else { return .silent }
                let waited = await Waking.waitForAnswer(from: client, limit: limit, interval: interval,
                                                        packetSentAt: wentAt, resend: { _ = sendPacket() })
                return waited == .answered ? nil : .silent
            }), wakesAfterRefusal: true)
        return outcome == .answered
    }

    /// Whether the recorder that has just answered is the one this phone's cache is of, or the first it has
    /// heard from (`GuideStore.recognises`). The saved address may be answered by another: one the reader has
    /// typed and not yet seen answer, or one the router has handed the address to. The screens take such a
    /// recorder up (`attach`); with no screen nothing is taken up and nothing sent, since the queue was made for
    /// the recorder known and the guide would go into a cache that is still its own. Nor when it cannot be told:
    /// an owner that cannot be read, a device that did not describe itself.
    public nonisolated static func isTheOneKnown(_ client: RecorderClient, to store: GuideStore) async -> Bool {
        guard let answering = await client.info, let who = try? await store.recognises(answering) else {
            return false
        }
        return who != .another
    }
}

/// How long the USB slot is waited for before something that names it is sent, while it answers none
/// (`RecorderDriver.settle`): read again every `interval`, until `limit` has gone by. Handed to a link with its
/// surroundings (`LinkEnvironment.slotSettling`) and to a client for the queue's round, where a test gives less.
public struct SlotSettling: Sendable, Equatable {
    public var interval: Duration
    public var limit: Duration

    public init(every interval: Duration, for limit: Duration) {
        self.interval = interval
        self.limit = limit
    }

    /// Every two seconds for ten: twice the five seconds after which a BDZ-FBT4100, timed once right after a
    /// waking, answered the disk it had first answered as none (`RecorderDriver.slotReadAgainAfter`).
    public static let afterAWaking = SlotSettling(every: .seconds(2), for: .seconds(10))

    /// How many times the slot is read at most: once, and once more after each interval the limit holds.
    var reads: Int { interval > .zero ? 1 + max(0, Int(limit / interval)) : 1 }
}

/// What the USB slot came to, read until it answered a disk or its time was up (`RecorderDriver.settle`).
public enum SlotSettled: Sendable, Equatable {
    /// A registered disk, as the slot answered it.
    case answered(RecorderDisk)
    /// No disk, each time it was read.
    case noDisk
    /// Nothing answered: the recorder has gone.
    case silent
    /// Whoever waited for it gave up first.
    case cancelled
}
