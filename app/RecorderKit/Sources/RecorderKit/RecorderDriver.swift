import Foundation

/// What is particular to a BDZ recorder in a link: it is woken by a magic packet and waited for, found at another
/// address by the MAC at the end of its UDN, recognised by that UDN, and read on every attach for its firmware,
/// its MAC, its free space and the disk in its USB slot, which are only shown or kept and must not fail the
/// attach; a USB disk known is not let go of on one answer of none (`learnTheSlot`). The runs with no screen,
/// which have no link, make their attempt here too (`reachWithNoScreen`, `isTheOneKnown`).
///
/// What is asked of the recorder's reservations after its attach is here as well, as a television's is its
/// driver's: reading them (`reservations`, `refreshReservations`), sending what waits for the recorder in the
/// phone's queue (`sendWhatWaits`, `resend`), deleting and changing one (`cancel`, `update`), what a new one
/// would clash with (`conflicts`), and making one, or keeping it on the phone when the recorder cannot be asked
/// (`reserve`) -- the steps, and what each hands back for the app to keep.
@MainActor
public final class RecorderDriver: LinkDriver {
    /// The link holds the driver, so weak; it is set once, as the link is made. Each operation asked of the
    /// driver goes through on it, written on the parts of an operation the link carries (`DeviceLink.run`,
    /// `underALine`, `say`): the reads of the reservations, the sending of what waits and a waiting row sent
    /// again, a delete, a change and a reservation, and the slot's settling and what it came to. The clash check
    /// goes through on the link's check and its silence (`ensureUp`, `lost`), as it did in the app; the check
    /// before a reservation is read for its reason (`check`). The recorder's other operations are still the
    /// app's, and will be asked of this the same way.
    public weak var link: DeviceLink?
    /// Written on each reservation that was waiting when another recorder took the place of the one it was made
    /// for (`GuideStore.claim`): `heldForAnotherRecorder`, unless a test gives a sentence of its own.
    private let heldWith: String
    /// How long the screens wait for the recorder to answer after the packet, and how often they ask meanwhile.
    private let wakingLimit: TimeInterval
    private let wakingInterval: Duration
    /// How long a client waits before sending again what the recorder answered 503 (`RecorderClient`).
    private let busyRetryDelay: ClosedRange<Double>
    /// The read of the reservations that is out, with the count of recorders let go of it was asked under
    /// (`DeviceLink.generation`) and the client the link held then, which whoever asks under the same count, the
    /// link holding the same client, meanwhile waits for; and how many reads have been begun, which tells the
    /// one out from one begun after it.
    private var reading: (generation: Int, client: ObjectIdentifier, number: Int, list: Task<[Reservation]?, Never>)?
    private var readsBegun = 0

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

    /// Said when something the reader asked for was not sent at all because the app is not connected to the
    /// recorder, unless the local network permission is why (`whyNotConnected`).
    public nonisolated static let notConnected = "レコーダーに接続していません。「再接続」を押してから、もう一度お試しください。"

    /// Why something the reader asked for was not sent at all: the app is not connected. While the local network
    /// permission is what stands in the way (`SessionState.connectBlocked`), the title the screens give that
    /// (`LocalNetwork.accessNotAllowed`); otherwise `notConnected`. What the host says when the link has nothing
    /// to ask (`LinkHost.sayNotConnected`).
    public var whyNotConnected: String {
        link?.session.connectBlocked == true ? LocalNetwork.accessNotAllowed : Self.notConnected
    }

    /// Said when something the reader asked for was not done because another recorder answered where the
    /// one it was meant for had been. Not only what is sent: a read comes through the same check. What the host
    /// says when the check before an operation hears another (`LinkHost.anotherAnsweredTheCheck`).
    public nonisolated static let anotherAnswered = "別のレコーダーが応答したため、この操作は行っていません。"
        + "一覧を読み直しますので、確かめてからもう一度お試しください。"

    /// Only while the recorder is not known to be away already: silence is said once, as a television's is, so
    /// that a read which waited its turn behind the request that met it does not write over what that one said
    /// -- something sent that may have arrived. Not by whether it is connected, as a television's goes: a
    /// recorder that answered without saying which it is is not connected, is read all the same, and its silence
    /// is to lose it and be said like any other.
    public func takesSilenceOnARead(_ link: DeviceLink) -> Bool { !link.session.unreachable }

    /// What a reservation, a change or a delete says when the recorder it was asked of was let go of on the way
    /// (`DeviceLink.letGo(since:)`). With no recorder in hand since -- the host let go of it over a cache it
    /// could not make over to the recorder that answered, or the check heard another that is still to be
    /// connected to -- whatever let go of it has said why on the line, and the result repeats it, as it repeats
    /// what a check that failed wrote there; that another recorder answered only where the line holds nothing.
    /// With another taken up in its place -- one that described itself on a connect, or the recorder at an
    /// address the reader chose -- the line is the newcomer's, and the result says that another recorder
    /// answered (`anotherAnswered`).
    private func whyLetGo(on link: DeviceLink) -> String {
        link.client == nil ? link.owner?.problem ?? Self.anotherAnswered : Self.anotherAnswered
    }

    /// Whether the line says that something sent met silence and may have arrived (`mayHaveArrived`,
    /// `reservationMayHaveArrived`): all the reader has to go by until the recorder answers, which what an attach
    /// or a waking meets on the way does not write over.
    private static func saysItMayHaveArrived(_ line: String?) -> Bool {
        line == mayHaveArrived || line == reservationMayHaveArrived
    }

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
    /// in either has not reached anything to show. Once the description and what goes with it have been read, and
    /// before what waits is sent, the client is the one whose attach went through (`DeviceLink.attachedClient`),
    /// as a television's attach has it: what is asked from inside the attach is asked of that client.
    ///
    /// An attach that fails says why on the host's line, but for silence over a line that says something sent
    /// may have arrived, as a television's attach leaves it: that the recorder is silent still adds nothing to it.
    /// One that goes through clears the line.
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
            link.attachedClient = client
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
            let saidAlready = deviceError?.failure == .silent && Self.saysItMayHaveArrived(owner?.problem)
            if !saidAlready, !quiet || !link.session.unreachable {
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
        // It has said which it is: whatever a check heard in its place before says nothing of it now.
        link.heardInstead = nil
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
    /// meets it does; nothing has been sent. Not when the recorder was let go of while the slot was read
    /// (`DeviceLink.say(_:since:ofARead:)`): the silence is not the one in play's, and nothing is said or lost. What it
    /// came to is handed back. Nil, with nothing asked, for any other destination, and for a disk the slot has
    /// answered since the recorder last answered: in a home with no USB disk nothing is added.
    public func settleTheSlot(for destination: String) async -> SlotSettled? {
        guard destination == RecorderDisk.usbID, let link, link.session.usbDiskUnanswered, !link.offline,
              let client = link.client as? RecorderClient else { return nil }
        let owner = link.owner
        let began = link.generation
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
            _ = link.say(.silentOnARead(sentence: noAnswerLine), since: began)
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
    /// way must not leave the app given up on a recorder that is coming up. The line of what went wrong is
    /// cleared as it begins and says so when the recorder does not answer, but for a line that says something
    /// sent may have arrived, which stays as it is.
    public func wakeAndAttach(_ link: DeviceLink, client: any LinkClient) async -> Bool {
        guard link.session.unreachable, link.session.mac != nil else { return false }
        sendPacket(link)   // again: the attempt sends one too, and a second costs nothing
        let owner = link.owner
        // Nothing is wrong yet, so nothing on screen should say there is; but that something sent may have arrived
        // is still all the reader has to go by.
        if !Self.saysItMayHaveArrived(owner?.problem) { owner?.problem = nil }
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
        if !Self.saysItMayHaveArrived(owner?.problem) {
            owner?.problem = "レコーダーが応答しません。電源とネットワーク接続を確認してください。"
        }
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

    /// Whether what the reader asks of the recorder may be written to it, as a television's driver asks the
    /// same (`TVDriver.canBeAsked`): the client in hand is the one whose attach went through
    /// (`DeviceLink.clientIsAttached`), and the session is connected. A connect under way has a client of its
    /// own that has not yet heard which recorder answers it; a reconnect answered busy leaves the session
    /// connected from the attach before, beside a client that never heard it; and a check whose waking the
    /// recorder turned away leaves the attached client in hand with the session not connected. In each the
    /// recorder has not said which it is, and nothing is written to it. Reads go as they always have. Never with
    /// the link gone. A check before an operation that heard something else than the recorder saying which it is
    /// leaves this as it was, as a television's: what is asked next makes the check again, and writes only once
    /// a check has heard it (`DeviceLink.mayBeSent`).
    public var canBeAsked: Bool { link.map { canBeAsked(on: $0) } ?? false }

    private func canBeAsked(on link: DeviceLink) -> Bool {
        link.clientIsAttached && link.session.connected
    }

    /// The line on screen while the reservations are read.
    public static let readingLine = "予約一覧を取得中"

    /// What the recorder is set to record, read now: nil when it could not be read, and the host's line says
    /// why. With no recorder's client, or the recorder silent at the last ask, nothing is sent and nothing is
    /// said: every screen asks this as it appears, and a recorder known to be away costs no timeout.
    ///
    /// One operation through the link (`DeviceLink.run`): under a line of its own, the recorder made sure of
    /// first -- inside a connect, which has just heard it, at once -- and a read that goes through clears the
    /// line of what went wrong. It is sent on the client `run` hands over, the one in hand as the check was
    /// asked. A read that is a step of something else -- before a delete or a change, after a reservation or a
    /// sending -- has no line of its own and goes under that operation's, as a television's does: the reader
    /// sees one line for what they asked for, up from its check to its last read, with no moment between its
    /// steps in which nothing is.
    ///
    /// After a check that heard something in place of the recorder saying which it is, nothing is sent, as for
    /// a television's read: what it heard is what the read fails as, and the link says it
    /// (`DeviceLink.heardInstead`). The read after such a check checks again, however lately the recorder
    /// answered (`DeviceLink.checksAgain`).
    ///
    /// A list that comes back once the recorder has been let go of -- another has described itself, or another
    /// address was chosen -- is not handed back, and the line is left as it is; its silence is neither said nor
    /// taken for the recorder in play (`DeviceLink.run`). A read that is a step of something else goes by the
    /// count that operation noted as it began.
    ///
    /// One read at a time, as a television's: the list is asked for when a screen appears, when it is pulled
    /// down, when the recorder has just been connected to and by the steps of an operation, and these come
    /// together. Whoever asks while a read is out, under the same count of recorders let go of and with the
    /// link holding the client it went out on, gets its answer, and no second request is sent. A read begun
    /// before a let-go is never joined by one asked after it, which reads for the recorder in play; nor is one
    /// out on a client a connect has since put another in place of -- the recorder found at another address,
    /// or connected to again -- by one that reads on the connect's. One still out when a write has gone
    /// through was sent after that write -- the client sends one request at a time -- so its answer shows it.
    /// The line is the one the read that went out was asked under.
    public func reservations() async -> [Reservation]? {
        await reservations(since: link?.generation)
    }

    private func reservations(since began: Int?, underALine: Bool = true) async -> [Reservation]? {
        guard let link, let client = link.client as? RecorderClient, !link.session.unreachable else { return nil }
        let generation = began ?? link.generation, asking = ObjectIdentifier(client)
        if let reading, reading.generation == generation, reading.client == asking {
            return await reading.list.value
        }
        readsBegun += 1
        let number = readsBegun
        let read = Task { () -> [Reservation]? in
            defer { if self.reading?.number == number { self.reading = nil } }
            return await self.readNow(link, since: generation, underALine: underALine)
        }
        reading = (generation, asking, number, read)
        return await read.value
    }

    /// The read itself, as one operation through the link.
    private func readNow(_ link: DeviceLink, since began: Int, underALine: Bool) async -> [Reservation]? {
        let line = underALine ? Self.readingLine : nil
        let read = await link.run(line: line, evenIfRecent: link.checksAgain, since: began) { client in
            if let heard = link.heardInstead { throw heard }
            return try await (client as? RecorderClient)?.reservations()
        }
        if case .success(let list) = read { return list }
        return nil
    }

    /// What pulling the list down asks for, as a television's: when something can be written to the recorder
    /// (`canBeAsked`), what waits is sent, and then the list is read now, as `reservations` reads it, so that
    /// what was just made is in it. The list read, nil when none was. The sending is asked through the host,
    /// as an attach asks it (`LinkHost.sendWhatWaits`): the host says what became of it, and keeps the list
    /// the sending read, when it read one. One that lost the recorder has nothing read after it: `reservations`
    /// asks nothing of a recorder known to be away.
    ///
    /// When nothing can be written to it, the reader has asked for it to be tried again: a connect, which
    /// sends what waits and reads the list once the recorder has answered (`attach`, `LinkHost.reached`), and
    /// nil -- what a connect that got nowhere has to say is on its line. That is so of a recorder the app is not
    /// connected to, and of one whose last connect it answered busy with somebody else, as it was asked which
    /// it is: neither is offline, the queue does not go to them (`sendWhatWaits`), and for the second no
    /// 再接続 is offered, the app being connected from the attach before.
    public func refreshReservations() async -> [Reservation]? {
        guard let link else { return nil }
        guard canBeAsked(on: link) else {
            await link.connect()
            return nil
        }
        await link.owner?.sendWhatWaits()
        return await reservations()
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
    /// none was. Asked by the host whenever the recorder has just answered, which means from inside an attach,
    /// and when the list is pulled down (`refreshReservations`): nothing here waits for the app's start.
    ///
    /// Only to a recorder that has described itself, on the client whose attach heard it (`canBeAsked`), and
    /// made sure of first: the check before an operation goes under the sending's line, as a television's
    /// does, made whatever the time since the recorder last answered when the check before heard something in
    /// its place (`DeviceLink.checksAgain`). A recorder that has dozed off the LAN is woken by it, rather than
    /// sent creates it does not hear, whose silence would lose it. Inside an attach -- a connect's, or a
    /// waking's -- the check answers at once. Nothing is sent once the check has said no, nor after a check
    /// that heard something in place of the recorder saying which it is (`DeviceLink.mayBeSent`): whatever
    /// answers a connect some other way -- a 503, or as something that is no recorder -- must not be handed
    /// what was waiting for the last recorder, nor must whatever a check hears busy or faulted. Nothing is
    /// said here of a sending not made: the pull-down's read after it says what the check heard.
    ///
    /// The queue is looked at before the recorder is, as a television's: only with something in it to send --
    /// a row of the recorder's with no reason on it whose programme is not over
    /// (`PendingQueue.hasSomethingToSend`) -- is the recorder made sure of and a line put up. Rows with a reason
    /// on them wait for the reader, those held for another recorder among them, and would otherwise put the line
    /// up at every connect for as long as they waited. Rows whose programmes are over are still dropped, with no line and
    /// no check, which asks the recorder nothing. What waits for the television is its own driver's to send
    /// (`TVDriver.sendWhatWaits`): with nothing but such rows the recorder's line would go up for a flush that
    /// sends nothing, and that flush would wait its turn behind a television's sending that is out. With
    /// nothing to send or to drop, nothing is asked and nothing said, and no round runs: the host says what is
    /// held for another recorder all the same. The host is told the queue may have changed as it is looked at
    /// and after the round (`LinkHost.queueWritten`), so that the screens read it again.
    ///
    /// The list is read after a round that made something only where nothing else reads it: after the attach
    /// of a waking that a check began, outside any connect (`SessionState.waking`), so that the row that left
    /// the queue is on screen as a reservation and its programme is not offered the recorder again. A
    /// connect's attach has its list read as the connect gets there (`LinkHost.reached`), and a pull-down
    /// reads it after the sending.
    ///
    /// The count of recorders let go of is noted as this is asked, with the client and the question whether it
    /// can be asked; once the queue has been read, and again once the check has answered, both are asked again,
    /// and nothing is sent when the recorder was let go of meanwhile (`DeviceLink.letGo(since:)`) or may no
    /// longer be sent to. The rows go on the client the link holds once the check has answered, and a list read
    /// after them goes under the sending's line. What had not been sent when the recorder fell silent stays
    /// queued for the next answer, and the recorder is lost as for any silence, with nothing said: as it is
    /// today; a later change says on the line that what was out may have arrived. Not lost when it was let go
    /// of while the round was out: the silence is not the one in play's, and the list read after it is not kept
    /// for it either. A round that waits for the queue's turn sends on its client when its turn comes, whatever
    /// became of the recorder meanwhile (`PendingQueue.flush`): as it is today. What became of the round is
    /// the host's to say.
    public func sendWhatWaits() async -> (round: PendingQueue.Outcome?, list: [Reservation]?) {
        await sendWhatWaits(forARowSentAgain: false)
    }

    /// The sending. `forARowSentAgain`: under the line of `resend`, which has made the check already, and with
    /// the list read after every round that made something, for `resend` to hand back.
    private func sendWhatWaits(forARowSentAgain: Bool) async -> (round: PendingQueue.Outcome?,
                                                                   list: [Reservation]?) {
        guard let link, link.client is RecorderClient, let store = link.owner?.cache, canBeAsked(on: link) else {
            return (nil, nil)
        }
        let began = link.generation
        await link.owner?.queueWritten()
        let now = Date()
        let rows = ((try? await store.pendingReservations()) ?? []).filter { $0.target == RecorderClient.slot }
        let toGo = PendingQueue.hasSomethingToSend(rows, for: RecorderClient.slot, now: now)
        // Asked again once the queue has been read: the recorder may have been let go of meanwhile, or a check
        // have heard something in its place.
        guard toGo || rows.contains(where: { $0.request.end < now }), !link.session.unreachable,
              !link.letGo(since: began), canBeAsked(on: link) else {
            return (nil, nil)
        }
        // Rows only to drop, whose programmes are over, ask the recorder nothing: no line and no check for them.
        return await link.underALine(forARowSentAgain || !toGo ? nil : Self.sendingLine)
            { _ -> (round: PendingQueue.Outcome?, list: [Reservation]?) in
            if !forARowSentAgain, toGo {
                guard case .up = await link.check(evenIfRecent: link.checksAgain) else { return (nil, nil) }
            }
            // The client is the one the link holds now, once the check has answered.
            guard !link.session.unreachable, !link.letGo(since: began), link.mayBeSent,
                  let client = link.client as? RecorderClient else {
                return (nil, nil)
            }
            let round = await PendingQueue.flush(client: client, store: store)
            if round.interrupted, !link.letGo(since: began) { link.lost() }
            await link.owner?.queueWritten()
            let readsAfter = forARowSentAgain || (link.session.waking && !link.session.connecting)
            let list = round.sent.isEmpty || !readsAfter
                ? nil : await self.reservations(since: began, underALine: false)
            return (round, list)
        }
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
    /// is known to be away. Otherwise the sending's line goes up before the check, as a television's row sent
    /// again has it, and stays up through the sending and the read after it. When the check says no, the row
    /// goes the next time the recorder answers. There, and nothing can be written to it (`canBeAsked`) -- not
    /// connected, or connected from an attach before a reconnect it answered without saying which it is -- a
    /// connect asks it again once the line is down, and its attach sends what waits if it describes itself. A
    /// check that heard something in place of the recorder saying which it is sends nothing either, and what
    /// it heard is said here, at the door (`DeviceLink.mayBeSent`): the row goes once a check or an attach hears
    /// the recorder. Otherwise what waits is sent now.
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
        guard !link.offline else { return (nil, nil, nil) }
        let sent = await link.underALine(Self.sendingLine) { _ -> (round: PendingQueue.Outcome?,
                                                                  list: [Reservation]?)? in
            guard await link.ensureUp(evenIfRecent: link.checksAgain) else { return (nil, nil) }
            // The connect goes once the line is down: it has a line of its own.
            guard self.canBeAsked(on: link) else { return nil }
            guard link.mayBeSent else {
                self.sayWhyNotSent(on: link)
                return (nil, nil)
            }
            return await self.sendWhatWaits(forARowSentAgain: true)
        }
        guard let sent else {
            await link.connect()
            return (nil, nil, nil)
        }
        return (sent.round, sent.list, nil)
    }

    // MARK: - deleting one

    /// The line on screen while a reservation is deleted.
    public static let deletingLine = "予約を削除中"

    /// Said when a reservation to delete or to change is not in the list just read, and the list on screen is the
    /// one just read. Not that it was deleted, as a television's says (`TVDriver.notInList`): all that is seen is
    /// that the list lists it nowhere, and the list is one request of at most 200 rows.
    public static let notInList = "この予約はレコーダーの予約一覧に見つかりませんでした。一覧を更新しました。"

    /// Said when the recorder answers a delete or a change that it holds no such reservation (804 or 820) though
    /// the list just read had one: that list was itself out of date, and it has been read again. And when the
    /// list just read has the reservation's id on another programme (`ReservationFoundAgain.changed`): nothing was
    /// sent, and the list on screen is that one.
    public static let renumbered = "レコーダー側で予約が更新されていました。一覧を更新したので、もう一度お試しください。"

    /// Said when a write met silence. Whether it arrived is not known, which is exactly why it is not sent
    /// again, and what the list says once the recorder answers is the only way to find out.
    public nonisolated static let mayHaveArrived = "送信の途中でレコーダーの応答がなくなりました。届いている場合もあるため、"
        + "送り直していません。再接続してから一覧で確かめてください。"

    /// Deletes one of the recorder's reservations, as the recorder holds it now rather than by the id the app
    /// happens to hold. What it came to, with its sentence, and the freshest list read on the way for the caller
    /// to keep, nil when none was read. The result is nil for a row that is not the recorder's.
    ///
    /// The recorder rewrites the ids of the reservations its own automatic recording made, the whole block of
    /// them at once, when it works through the guide again (`Reservation.createdByRecorder`): an id read a few
    /// hours ago can be dead while the row still looks right, and deleting it answers 804. So the list is read
    /// again first (`reservations`) and this reservation found in it (`target(of:)`): by its id while that still
    /// stands on the same programme, and otherwise by its channel, the moment it starts, its programme and who
    /// made it -- but for one an app made, which the recorder has not been seen to renumber.
    ///
    /// A reservation that is not the recorder's is refused before anything else: nothing is read, sent or said
    /// for it, and there is no result. It is another device's to delete. Turned away at the door, with nothing
    /// read or sent and no line -- the sentence is in the result, and what an earlier operation left on the
    /// line stays (`Reserved`): the link gone; no recorder's client in hand; the recorder known to be away --
    /// the list has to be read first, and nothing can be read; nothing that can be written to it (`canBeAsked`),
    /// a connect being under way, or the recorder not having said which it is. Each says that the app is not
    /// connected (`whyNotConnected`).
    ///
    /// The delete goes only from a list read now, as a television's does: a read that did not go through ends it
    /// there, nothing sent, under whatever the read's failure left on the line -- silence, a refusal, busy with
    /// somebody else, a check inside the read that said no or heard something in place of the recorder saying
    /// which it is -- which the result says again. A reservation not in the list just read is not sent for, and
    /// the result says it was found nowhere in that list (`notInList`); one whose id now stands on another
    /// programme is not written to, and the result says the recorder has updated it and asks for another try
    /// from the list just read (`renumbered`). The read has cleared the line in both.
    ///
    /// The delete's line goes up before the read and stays up until the last read after it, as a television's
    /// does: the reads on the way have none of their own. The delete is sent once, on the client the link holds
    /// after the read: a connect made while the read was out has a client of its own, and one kept from before
    /// would send beside it, or to an address the recorder has left. That client is asked again whether it may
    /// be written to (`DeviceLink.mayBeSent`): one whose connect is still under way, which the read went through
    /// on, sends nothing, and the result says that the app is not connected -- or what a check heard in place of
    /// the recorder saying which it is, which goes on the line as well, being the recorder's answer. Silence
    /// there may be a delete that arrived: nothing is sent after it, the recorder is lost, and the line and the
    /// result say it may have arrived. 804 or 820 -- the list just read was itself out of date -- has the list
    /// read again first, and then the result says so (`renumbered`), as a television's does; when that read does
    /// not go through, what it failed with is left on the line and said in the result, the list not having been
    /// updated. Any other failure is said on the line by the link (`DeviceLink.say`) and in the result: a
    /// refusal in the recorder's words, the recorder kept and nothing read after it, and an error that is no
    /// device's as Swift describes it.
    ///
    /// After a delete that went through the list is read once more, and the row is taken out of whatever comes
    /// back -- that read, or the one before it when that read did not go through: a recorder a moment behind
    /// itself must not bring it back, and the delete counts though that read fails.
    ///
    /// The delete is for the recorder in play as it was asked for. Let go of before it is sent -- another has
    /// described itself while the read was out, or another address was chosen -- and nothing is sent or
    /// written, and the delete is not done, saying that another recorder answered, or what let go of it said
    /// when no recorder is in hand since (`whyLetGo`): a row of the same number on the newcomer is not this one.
    /// Let go of while the delete is out, its silence is said as ever, since it may have arrived, but loses
    /// nobody: the recorder now in play has not been asked anything (`DeviceLink.say(_:since:ofARead:)`); taken, it
    /// leaves the line alone, which is the newcomer's. The reads go by the same count.
    public func cancel(_ reservation: Reservation) async -> (deleted: Altered?, list: [Reservation]?) {
        guard reservation.device == .recorder else { return (nil, nil) }
        guard let link else { return (.notDone(Self.notConnected), nil) }
        let owner = link.owner
        guard link.client is RecorderClient, !link.offline, canBeAsked(on: link) else {
            return (.notDone(whyNotConnected), nil)
        }
        // What a read that failed left on the line, said again: a check's no for the permission leaves none, and
        // that the app is not connected stands for it.
        func whatTheLinkSaid() -> Altered { .notDone(owner?.problem ?? whyNotConnected) }
        let began = link.generation
        return await link.underALine(Self.deletingLine) { _ -> (deleted: Altered?, list: [Reservation]?) in
            let read = await self.reservations(since: began, underALine: false)
            guard !link.letGo(since: began) else { return (.notDone(self.whyLetGo(on: link)), nil) }
            guard let read else { return (whatTheLinkSaid(), nil) }
            let target: Reservation
            switch read.target(of: reservation) {
            case .found(let row):
                target = row
            case .gone:
                return (.notDone(Self.notInList), read)
            case .changed:
                return (.notDone(Self.renumbered), read)
            }
            guard let client = link.client as? RecorderClient else { return (.notDone(self.whyNotConnected), read) }
            guard link.mayBeSent else { return (.notDone(self.whyNotSent(on: link)), read) }
            do {
                try await client.deleteReservation(id: target.id)
            } catch {
                if (error as? any DeviceError)?.failure == .unknownItem {
                    let newer = await self.reservations(since: began, underALine: false)
                    return (newer == nil ? whatTheLinkSaid() : .notDone(Self.renumbered), newer ?? read)
                }
                let said = link.say(OperationFailure(error, sending: Self.mayHaveArrived), since: began)
                return (said.sentence.map { .notDone($0) } ?? whatTheLinkSaid(), read)
            }
            if !link.letGo(since: began) { owner?.problem = nil }
            let after = await self.reservations(since: began, underALine: false)
            return (.done(saying: nil), (after ?? read).filter { $0.id != target.id })
        }
    }

    // MARK: - changing one

    /// The line on screen while a change is out.
    public static let changingLine = "予約を変更中"

    /// Said when a mode or a repeat the tables do not know is asked of the recorder: nothing could be built to
    /// send. No screen offers one; a reservation or a change that met one would otherwise have nothing to say.
    public static let notInTheTables = "この録画モードと毎回録画の組み合わせは、レコーダーに送れません。"

    /// Said when the wait for the slot before something that names the USB disk was given up on by whoever
    /// waited (`Withheld.givenUp`): nothing was sent.
    public static let slotWaitGivenUp = "録画先のディスクの確認を中断したため、送っていません。"

    /// Said of a reservation the recorder says it is recording: it is not changed while it records.
    public nonisolated static let changeRecording = "録画中の予約は変更できません。"
    /// Said of a reservation whose end has passed: there is nothing left of it to change.
    public nonisolated static let changeEnded = "放送が終わった予約は変更できません。"

    /// Why one of the recorder's reservations cannot be changed now, or nil when it can. One the recorder says
    /// it is recording, by its own flag, which it lists from the moment a recording starts, and that is settled
    /// without the clock, so it comes first. Then one whose end has passed. Not the television's rule, which
    /// goes by the programme's start (`TVDriver.whyNot(changing:now:)`): the recorder says when it records, and a
    /// television's status has never been read during a recording. For the door of `update`, which asks it of
    /// the row held and again of the row just read, and for the sheets, which offer no change the door would
    /// turn away.
    public nonisolated static func whyNot(changing reservation: Reservation, now: Date = Date()) -> String? {
        if reservation.recording { return changeRecording }
        return reservation.end <= now ? changeEnded : nil
    }

    /// Changes the quality, the repeat or the disk of one of the recorder's reservations, found again in a list
    /// read afresh, as for a delete (`cancel`). The request keeps everything else, including the programme id, so
    /// a reservation that follows its programme goes on following it. What it came to, with its sentence, and the
    /// freshest list read on the way for the caller to keep, nil when none was read. The result is nil for a row
    /// that is not the recorder's: it is another device's to change, and nothing is read, sent or said for it,
    /// nor the disk not had forgotten.
    ///
    /// `disk` is where the reader moved the reservation, nil where they did not: the disk the recorder holds it on
    /// as the change goes out is then kept, whatever the sheet was opened on. A disk moved to and no longer offered
    /// is refused before the list is read, as a new reservation's is, and said by what the sheet has left to offer
    /// (`refuse`). A change that goes to the USB disk -- moved there, or of a reservation on it -- while the slot
    /// has not answered the disk since the recorder last answered waits for the slot once the list has been read,
    /// and is refused the same way when the slot does not answer it (`withholds`). `now` is when the change is
    /// asked, for the door's rule: the screens ask it now, and a rehearsal of the device check on a guide of the
    /// past passes the time it rehearses at.
    ///
    /// What a door turns away, with nothing sent, is said in the result and not on the line, which keeps what an
    /// earlier operation or the read on the way left there (`Reserved`): the link gone; a reservation being
    /// recorded, or over (`whyNot(changing:)`); no recorder's client in hand; the recorder known to be away --
    /// the list has to be read first, and nothing can be read -- or nothing that can be written to it
    /// (`canBeAsked`), a connect being under way, or the recorder not having said which it is, each that the app
    /// is not connected (`whyNotConnected`); a disk refused; a mode or a repeat the tables do not know
    /// (`notInTheTables`); a wait for the slot given up on (`slotWaitGivenUp`). The read makes sure of the
    /// recorder too, and wakes it if it has gone to sleep. The change goes only from a list read now, as the
    /// delete does: a read that did not go through ends it there, nothing sent, under whatever its failure left on
    /// the line, which the result says again; so does silence while the slot is waited for. A reservation not in
    /// the list just read is not sent for, and the result says so (`notInList`); one whose id now stands on
    /// another programme is not written to, as for a delete (`renumbered`): the read has cleared the line in
    /// both. Nor is one the row just read shows recording or over: the door's rule is asked again of that row,
    /// as long after `now` as the read took, and said in the result alone. The request is built from the row just found, on
    /// the client the link holds after the read, asked again whether it may be written to, as the delete's is
    /// (`DeviceLink.mayBeSent`): what a check heard in place of the recorder saying which it is goes on the line
    /// as well, being the recorder's answer.
    ///
    /// The change's line goes up before the read and stays up until the last read after it, the slot's line above
    /// it while the slot is waited for; the reads on the way have none of their own, as a television's change has
    /// it. The change is sent once. Silence there may be a change that arrived: nothing is sent after it, the
    /// recorder is lost, and the line and the result say it may have arrived (`DeviceLink.say`). 804 or 820 has
    /// the list read again first, and then the result says so; a read that does not go through leaves what it
    /// failed with, as for a delete. Any other answer of the recorder's is said by the disk the change named
    /// (`RecorderDisk.turnedDown`), and an error that is no device's as Swift describes it, on the line and in
    /// the result. After a change that went through the line is cleared and the list read again; when that read
    /// does not go through, the list handed back is the one read before, with the row given the mode, the repeat
    /// and the disk sent, as a television's change hands back what it sent: the change was answered as made.
    ///
    /// The change is for the recorder in play as it was asked for. Let go of before it is sent -- while the read
    /// was out, or the slot waited for -- and nothing is sent or written, and the change is not done, saying that
    /// another recorder answered, or what let go of it said when no recorder is in hand since (`whyLetGo`): a
    /// row of the same number on the newcomer is not this one.
    /// After the slot, the client is asked again whether it may be written to (`DeviceLink.mayBeSent`), since a
    /// check by another operation may have heard something in place of the recorder meanwhile, and nothing is
    /// sent then either, said as at the door; and the change goes on the client the link holds then, which a
    /// connect to the same recorder made while the slot was waited for -- one found at another address among
    /// them -- has made anew. Let go of while the change is out, its silence is said, but loses nobody
    /// (`DeviceLink.say(_:since:ofARead:)`); taken, it leaves the line alone, which is the newcomer's. The reads go by
    /// the same count.
    public func update(_ reservation: Reservation, quality: String, repeating: String,
                       disk: String?, now: Date = Date()) async -> (altered: Altered?, list: [Reservation]?) {
        guard reservation.device == .recorder else { return (nil, nil) }
        clearTheDiskNotHad()
        guard let link else { return (.notDone(Self.notConnected), nil) }
        if let why = Self.whyNot(changing: reservation, now: now) { return (.notDone(why), nil) }
        let asked = Date()
        guard link.client is RecorderClient else { return (.notDone(whyNotConnected), nil) }
        if let disk, !RecorderDisk.offers(disk, with: link.session.usbDisk) {
            return (.notDone(refuse(reservation, goingTo: disk, on: link)), nil)
        }
        // Sending would only wait out a timeout, from a list that could not be read again first.
        guard !link.offline, canBeAsked(on: link) else { return (.notDone(whyNotConnected), nil) }
        let owner = link.owner
        // What a read, or the slot's silence, left on the line, said again, as for a delete.
        func whatTheLinkSaid() -> Altered { .notDone(owner?.problem ?? whyNotConnected) }
        let began = link.generation
        return await link.underALine(Self.changingLine) { _ -> (altered: Altered?, list: [Reservation]?) in
            let read = await self.reservations(since: began, underALine: false)
            guard !link.letGo(since: began) else { return (.notDone(self.whyLetGo(on: link)), nil) }
            guard let read else { return (whatTheLinkSaid(), nil) }
            let target: Reservation
            switch read.target(of: reservation) {
            case .found(let row):
                target = row
            case .gone:
                return (.notDone(Self.notInList), read)
            case .changed:
                return (.notDone(Self.renumbered), read)
            }
            // The door's rule again, of the row as the recorder lists it now and with the time the read took: a
            // recording begun while the sheet was open, or a programme the recorder has moved to end earlier.
            let later = now.addingTimeInterval(Date().timeIntervalSince(asked))
            if let why = Self.whyNot(changing: target, now: later) { return (.notDone(why), read) }
            guard link.client is RecorderClient else { return (.notDone(self.whyNotConnected), read) }
            guard link.mayBeSent else { return (.notDone(self.whyNotSent(on: link)), read) }
            guard let request = ReservationRequest(changing: target, quality: quality, repeating: repeating,
                                                   destination: disk)
            else { return (.notDone(Self.notInTheTables), read) }
            let withheld = await self.withholds(request.destination)
            guard !link.letGo(since: began) else { return (.notDone(self.whyLetGo(on: link)), nil) }
            switch withheld {
            case nil:
                break
            case .noDisk?:
                return (.notDone(self.refuse(reservation, goingTo: request.destination, on: link)), read)
            case .silence?:
                return (whatTheLinkSaid(), read)
            case .givenUp?:
                return (.notDone(Self.slotWaitGivenUp), read)
            }
            guard link.mayBeSent else { return (.notDone(self.whyNotSent(on: link)), read) }
            // The client the link holds now: a connect to the same recorder made while the slot was waited for
            // has one of its own, and the one before may be at an address the recorder has left.
            guard let client = link.client as? RecorderClient else { return (.notDone(self.whyNotConnected), read) }
            do {
                try await client.updateReservation(id: target.id, request)
            } catch let error as any DeviceError where error.failure == .silent {
                _ = link.say(.silentAfterSending(sentence: Self.mayHaveArrived), since: began)
                return (.notDone(Self.mayHaveArrived), read)
            } catch let error as any DeviceError where error.failure == .unknownItem {
                let newer = await self.reservations(since: began, underALine: false)
                return (newer == nil ? whatTheLinkSaid() : .notDone(Self.renumbered), newer ?? read)
            } catch let error as any DeviceError {
                // A move turned down is said by the disk moved to; a change that leaves the disk, as it always was.
                let said = RecorderDisk.turnedDown(error, sentTo: disk ?? RecorderDisk.internalID,
                                                   usb: link.session.usbDisk)
                owner?.problem = said
                return (.notDone(said), read)
            } catch {
                owner?.problem = String(describing: error)
                return (.notDone(String(describing: error)), read)
            }
            if !link.letGo(since: began) { owner?.problem = nil }
            if let after = await self.reservations(since: began, underALine: false) {
                return (.done(saying: nil), after)
            }
            var sent = target
            sent.qualityCode = request.qualityCode
            sent.repeatCode = request.repeatCode
            sent.destination = request.destination
            return (.done(saying: nil), read.map { $0.id == target.id ? sent : $0 })
        }
    }

    /// Why a change of `reservation` that goes to `disk` is not sent, the disk not to be had: by what its sheet
    /// has left to offer, which is the rule the sheet offers from (`RecorderDisk.choices(keeping:on:with:)`).
    /// Another disk than its own and that one, and the reader is asked to choose it; none, the picker gone or
    /// offering only those two, and the reader is told where it stays rather than asked for a choice the sheet
    /// does not show. For the result: nothing is written on the line.
    private func refuse(_ reservation: Reservation, goingTo disk: String, on link: DeviceLink) -> String {
        let usb = link.session.usbDisk
        let another = RecorderDisk.choices(keeping: reservation.destination, on: reservation.device, with: usb)
            .contains { $0.destination != reservation.destination && $0.destination != disk }
        return another ? RecorderDisk.chooseAnother(than: disk, usb: usb)
            : RecorderDisk.stays(on: reservation.destination, notMovedTo: disk, usb: usb)
    }

    // MARK: - what a reservation would clash with

    /// What a programme's sheet says when the recorder has named no reservation a new one would clash with.
    public static let noClashes = "時間が重なる予約はありません"

    /// The recorder's reservations that a reservation of `program` would clash with, as the recorder lists them;
    /// nil when it was not asked, or its answer could not be had. It is asked with the very payload a creation
    /// would send, so it also proves the payload is one the recorder accepts, without recording anything. `disk`
    /// is the one the sheet shows, so that the clashes are the ones on the disk the reservation would go to.
    ///
    /// The disk the last request found not to be had is forgotten as it begins, as for every request that can
    /// name a disk (`clearTheDiskNotHad`). With the link gone, no recorder's client in hand, the recorder silent
    /// at the last ask, or a mode or a repeat the tables do not know, nothing is asked and nothing said. The
    /// recorder is made sure of first, and woken if it is asleep (`DeviceLink.ensureUp`); when it cannot be, the
    /// check has said why. A USB disk the slot has not answered since the recorder last answered is waited for
    /// (`withholds`), and one not had is said as a reservation to it is, with no clashes asked; the slot
    /// silent or given up on says nothing more.
    ///
    /// No line of its own: it is asked as a programme's sheet opens, before anybody has asked for anything, and
    /// the line of what went wrong is left as it was by an answer. It is asked on the client in hand at the door,
    /// before the check. A failure is said on the line, silence losing the recorder, unless the link asks through
    /// another client by then.
    public func conflicts(for program: GuideProgramRow, quality: String, repeating: String,
                          disk: String) async -> [Reservation]? {
        clearTheDiskNotHad()
        guard let link, let client = link.client as? RecorderClient, !link.session.unreachable,
              let request = ReservationRequest(program: program, quality: quality, repeating: repeating,
                                               destination: disk)
        else { return nil }
        let owner = link.owner
        // Opening a programme is the moment to find out whether the recorder is still up, and to wake it if
        // not, so that the reservation which usually follows goes straight through.
        guard await link.ensureUp() else { return nil }
        if let withheld = await withholds(disk) {
            if withheld == .noDisk {
                owner?.problem = RecorderDisk.chooseAnother(than: disk, usb: link.session.usbDisk)
            }
            return nil
        }
        do {
            return try await client.conflicts(elements: XsrsElements.create(request))
        } catch {
            // As for a recording's details, which the app reads with the client it had in hand: what a client
            // the link no longer asks through ran into is not about the recorder in play, and is neither taken
            // for its silence nor put on its screens. As it is today, and to stay, by the client rather than by
            // whether the recorder was let go of meanwhile: a connect to the same recorder made while this was
            // out has a client of its own, and lets go of nothing.
            guard client === link.client else { return nil }
            let deviceError = error as? any DeviceError
            if deviceError?.failure == .silent { link.lost() }
            owner?.problem = deviceError?.explanation ?? String(describing: error)
            return nil
        }
    }

    // MARK: - reserving a programme

    /// The line on screen while a reservation the reader has just asked for is made.
    public static let reservingLine = "予約を登録中"

    /// Said of a reservation kept on the phone because the recorder could not be asked: it goes the next time
    /// the recorder answers.
    public static let keptUnsent = "レコーダーに届かなかったので、予約を端末に保存しました。"
        + "次にレコーダーにつながったときに登録します。予約タブで削除できます。"

    /// Said when a reservation met silence once it had gone out. Whether it arrived is not known, so it is
    /// neither kept nor sent again, and what the list says once the recorder answers is the only way to find out.
    public static let reservationMayHaveArrived = "予約の登録中にレコーダーの応答がなくなりました。届いている場合もあるため、送信待ちにはしていません。"
        + "再接続してから予約一覧で確かめてください。"

    /// What a screen says a reservation on the recorder will do, before the reader confirms it: registered, or,
    /// with the recorder known to be away (`away`), kept on the phone and registered at the next connect.
    public static func confirming(away: Bool) -> String {
        away ? "レコーダーに接続できないため、予約を端末に保存します。次につながったときに登録します。"
            : "レコーダーに予約を登録します。"
    }

    /// The title of that question while the recorder is known to be away, when the reservation is to wait on the
    /// phone.
    public static let keepingTitle = "この番組を送信待ちにしますか？"

    /// Reserves `program` on the recorder, in `quality`, with `repeating`, on `disk`: after this the recorder
    /// really will record it. What it came to, with its sentence, and the list read after a reservation made for
    /// the caller to keep, nil when none was read -- as `update` hands its list back.
    ///
    /// `disk` is the one the reader picked, sent as picked or not at all. The disk the last request found not to
    /// be had is forgotten first, as for every request that can name a disk (`clearTheDiskNotHad`). One no
    /// longer offered by the time it is sent -- let go of since the sheet offered it -- is refused before
    /// anything is kept or sent, since sending the internal disk in its place would make a reservation the
    /// reader did not agree to, and the result asks for another (`RecorderDisk.chooseAnother`). A mode or a
    /// repeat the tables do not know keeps and sends nothing (`notInTheTables`). With the link gone, the app is
    /// not connected. What a door turns away is said in the result and not on the line, which keeps what an
    /// earlier operation left there (`Reserved`).
    ///
    /// Known to be away -- no recorder's client in hand, or the recorder silent at the last ask -- it is kept on
    /// the phone at once (`keep`), with no check and no line, rather than spend a timeout finding out again. So
    /// it is when nothing can be written to the recorder (`canBeAsked`): a connect under way, whose own sending
    /// takes the row once the recorder has said which it is, or a recorder that has not said which it is.
    /// Otherwise, under a line of its own: the recorder is made sure of, and woken if it is asleep
    /// (`DeviceLink.check`). When it cannot be, nothing has been sent, and it is kept -- unless the check heard
    /// another recorder (`NotUp.anotherAnswered`), or the recorder was let go of since the reservation began: by
    /// the check's own waking (`NotUp.letGo`), or by anything else while the check was out, another address
    /// chosen among them, whatever the check then answers (`DeviceLink.letGo(since:)`). Then it is not done:
    /// kept, it would wait as one made for the recorder before, and go to whichever answers the next connect.
    /// When it answers, but heard something in place of the recorder saying which it is (`DeviceLink.mayBeSent`)
    /// -- busy with somebody else, a fault -- nothing is sent either: what it heard is said on the line, being
    /// the recorder's answer, and the reservation is kept, to go once the recorder has said which it is; by the
    /// same rule, not when the recorder was let go of meanwhile, when it is not done. The check is made however
    /// lately the recorder answered when the one before heard such a thing (`DeviceLink.checksAgain`). The slot
    /// is waited for when the reservation names a USB disk the slot has not answered since the recorder last
    /// answered (`withholds`): a disk not had is refused as one no longer offered is; silence is kept, as when
    /// the recorder could not be made sure of; a wait given up on ends it (`slotWaitGivenUp`).
    ///
    /// Whatever the slot came to, the recorder let go of since the reservation began (`DeviceLink.letGo(since:)`)
    /// -- not for a connect to the same recorder, whose client is new and which lets go of nothing -- the
    /// reservation is not done, nothing is sent, kept or written. Then the client is asked again whether it may
    /// be written to (`DeviceLink.mayBeSent`), since a check by another operation may have heard something in
    /// place of the recorder while the slot was waited for: nothing is sent, and the reservation is kept as at
    /// the door after the check.
    ///
    /// Every way the recorder can have been let go of on the way -- the check's no for another recorder or for
    /// the recorder let go of, a let-go after a check that said no or that heard something else, and one while
    /// the slot was waited for -- says the same in the result, by one rule (`whyLetGo`): that another recorder
    /// answered, or, with no recorder in hand since, what let go of it said on the line, such as the host's
    /// word that the cache could not be made over. Kept, the reservation would wait as one made for the
    /// recorder before, and sent, it would go to the newcomer.
    ///
    /// The create is sent once, on the client the link holds as it goes: the one in hand at the door, or the one
    /// a connect to the same recorder made while the slot was waited for -- one found at another address among
    /// them. Only silence before anything was sent is kept -- a recorder that answers and refuses has said
    /// something the reader needs to see -- and not silence after it: what went out may have been made all the
    /// same, and the queue would make it a second time. So the recorder is lost and the line and the result say
    /// it may have arrived (`reservationMayHaveArrived`), with nothing kept -- said all the same, but nobody lost,
    /// when the recorder was let go of while the create was out (`DeviceLink.say(_:since:ofARead:)`). Any other
    /// answer of the recorder's is said by the disk the reservation named (`RecorderDisk.turnedDown`), and an
    /// error that is no device's as Swift describes it, on the line and in the result. Made: the line of what went
    /// wrong is cleared and the list read again, under the reservation's line with none of its own, by the count
    /// noted as it began.
    public func reserve(_ program: GuideProgramRow, quality: String, repeating: String,
                        disk: String) async -> (reserved: Reserved, list: [Reservation]?) {
        clearTheDiskNotHad()
        guard let link else { return (.notDone(Self.notConnected), nil) }
        let owner = link.owner
        guard RecorderDisk.offers(disk, with: link.session.usbDisk) else {
            return (.notDone(RecorderDisk.chooseAnother(than: disk, usb: link.session.usbDisk)), nil)
        }
        guard let request = ReservationRequest(program: program, quality: quality, repeating: repeating,
                                               destination: disk)
        else { return (.notDone(Self.notInTheTables), nil) }
        guard link.client is RecorderClient, !link.offline, canBeAsked(on: link) else {
            return (await keep(request, serviceName: program.serviceName, on: link), nil)
        }
        let began = link.generation
        return await link.underALine(Self.reservingLine) { _ -> (reserved: Reserved, list: [Reservation]?) in
            switch await link.check(evenIfRecent: link.checksAgain) {
            case .up:
                break
            case .notUp(.anotherAnswered), .notUp(.letGo):
                return (.notDone(self.whyLetGo(on: link)), nil)
            case .notUp:
                // Nothing was sent; kept only for the recorder it was asked of.
                guard !link.letGo(since: began) else { return (.notDone(self.whyLetGo(on: link)), nil) }
                return (await self.keep(request, serviceName: program.serviceName, on: link), nil)
            }
            // What a check heard in place of the recorder saying which it is: said here, as nothing goes.
            @MainActor func keptAfterTheCheck() async -> (reserved: Reserved, list: [Reservation]?) {
                if let heard = link.heardInstead { owner?.problem = heard.explanation }
                return (await self.keep(request, serviceName: program.serviceName, on: link), nil)
            }
            guard link.mayBeSent else {
                guard !link.letGo(since: began) else { return (.notDone(self.whyLetGo(on: link)), nil) }
                return await keptAfterTheCheck()
            }
            let withheld = await self.withholds(disk)
            guard !link.letGo(since: began) else { return (.notDone(self.whyLetGo(on: link)), nil) }
            switch withheld {
            case nil:
                break
            case .noDisk?:
                return (.notDone(RecorderDisk.chooseAnother(than: disk, usb: link.session.usbDisk)), nil)
            case .silence?:
                // Nothing was sent, as when the recorder could not be made sure of.
                return (await self.keep(request, serviceName: program.serviceName, on: link), nil)
            case .givenUp?:
                return (.notDone(Self.slotWaitGivenUp), nil)
            }
            guard link.mayBeSent else { return await keptAfterTheCheck() }
            // The client the link holds now, as for a change.
            guard let client = link.client as? RecorderClient else { return (.notDone(self.whyNotConnected), nil) }
            do {
                try await client.create(request)
            } catch let error as any DeviceError where error.failure == .silent {
                _ = link.say(.silentAfterSending(sentence: Self.reservationMayHaveArrived), since: began)
                return (.notDone(Self.reservationMayHaveArrived), nil)
            } catch let error as any DeviceError {
                let said = RecorderDisk.turnedDown(error, sentTo: disk, usb: link.session.usbDisk)
                owner?.problem = said
                return (.notDone(said), nil)
            } catch {
                owner?.problem = String(describing: error)
                return (.notDone(String(describing: error)), nil)
            }
            owner?.problem = nil
            return (.made(saying: nil), await self.reservations(since: began, underALine: false))
        }
    }

    /// Keeps a reservation the recorder never heard on the phone, to go the next time it answers, and says so
    /// in the result rather than failing: the row as it waits, with `keptUnsent`. Not done when it could not be
    /// kept, the result saying why and the line left as it was: one that could not be saved has been made
    /// nowhere.
    ///
    /// The row is written at a whole second, as the cache keeps the moment, so that the row handed back is the
    /// row that waits. The write alone says whether it was kept, as for a television's: the queue is not read
    /// back, and a row written is one that goes. Kept, the line of what went wrong is left as it was, as a
    /// television's reservation kept leaves it: nothing was sent, and what the recorder or an earlier operation
    /// said there still stands. The host is told that the queue has changed (`LinkHost.queueWritten`). The
    /// system's question about notifications is asked by whoever asked for the reservation, once its line is
    /// down, and not here, where the line can still be up.
    private func keep(_ request: ReservationRequest, serviceName: String, on link: DeviceLink) async -> Reserved {
        let owner = link.owner
        guard let store = owner?.cache else { return .notDone(PendingQueue.noCache) }
        let queuedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let row = PendingReservation(request: request, serviceName: serviceName, queuedAt: queuedAt,
                                     target: RecorderClient.slot)
        do {
            try await store.queue(row)
        } catch {
            return .notDone(PendingQueue.couldNotBeKept(error))
        }
        await owner?.queueWritten()
        return .waiting(row, saying: Self.keptUnsent)
    }

    // MARK: - what the sheets offer and say

    /// The modes the recorder records in, by their names in `Codes.quality`, in the order a sheet lists them.
    public static let recordsIn = Codes.qualityOrder

    /// The repeats a reservation starting at `start` can be given on the recorder, by their names in
    /// `Codes.repeatCodes` and in the order a sheet lists them: the six, the weekly one the weekday of `start` in
    /// Japan. A weekly repeat has to fall on the programme's own weekday, so that is the only weekly one offered.
    public nonisolated static func repeats(startingAt start: Date) -> [String] {
        ["none", "title", "daily", Codes.weekdayRepeat(for: start), "mon-fri", "mon-sat"]
    }

    /// What a sheet says under the button that sends a change of the recorder's reservation: one that follows its
    /// programme goes on following it; one made by its times can have its mode and its repeat changed, and its
    /// disk while the sheet offers one to move it to.
    public static func changeFooter(followsItsProgramme: Bool, offersADisk: Bool) -> String {
        followsItsProgramme ? "番組追従はそのままです。"
            : offersADisk ? "時刻を指定した予約なので、録画モード・毎回録画・録画先だけを変えられます。"
            : "時刻を指定した予約なので、録画モードと毎回録画だけを変えられます。"
    }

    /// What the sheet of a reservation the recorder made by itself says of it (`Reservation.createdByRecorder`).
    public static let madeByItself = "おまかせ・まる録によって自動登録された予約です。削除してもレコーダーが再登録することがあります。"
        + "自動登録を止めるには、レコーダー本体でおまかせ・まる録の設定を変更してください。"

    /// What the question before such a reservation is deleted adds, asked on its sheet; `mayComeBackFromTheList`
    /// is the same asked from the list. Two wordings of one thing, kept as they are; a later review of the
    /// wording makes them one.
    public static let mayComeBack = "おまかせ・まる録による予約のため、レコーダーが再登録することがあります。"
    public static let mayComeBackFromTheList = "これはおまかせ・まる録によって自動登録された予約です。"
        + "削除してもレコーダーが再登録することがあります。"

    // MARK: - the check before an operation

    /// Asks which recorder answers, as an attach asks it first. Another one, by its UDN, is a stranger, and the
    /// link tells the host (`anotherAnsweredTheCheck`). Silence is the link's to read, as ever.
    ///
    /// Anything else -- busy with somebody else after the client's tries, a fault, an answer that does not
    /// read -- says nothing of which recorder gave it, and is kept on the link (`DeviceLink.heardInstead`), as
    /// a television's check keeps it: nothing is written to the recorder on its strength
    /// (`DeviceLink.mayBeSent`), the reads fail with it, and the next operation checks again however lately
    /// the recorder answered (`DeviceLink.checksAgain`). Any description heard clears it, as an attach's does
    /// (`settle`). The link takes such an answer for one, and lets the operation go on to this driver.
    ///
    /// Unlike a television's, the check writes nothing on the line: what it heard is said by the operation it
    /// stops -- a read through the link, which says how it failed (`DeviceLink.say`), a write at its door. The
    /// recorder has a request the television has not, the question of what a reservation would clash with,
    /// which goes on after such a check, reads nothing of what it heard, and leaves the line as it was.
    public func check(_ link: DeviceLink, client: any LinkClient) async -> (failure: DeviceFailure?, stranger: Bool) {
        guard let client = client as? RecorderClient else { return (.unexpected("not a recorder's client"), false) }
        do {
            let answering = try await client.describe(timeout: probeTimeout)
            link.heardInstead = nil
            return (nil, link.session.recognises(answering) == .another)
        } catch let heard as any DeviceError where heard.failure != .silent {
            link.heardInstead = heard
            return (heard.failure, false)
        } catch {
            return ((error as? any DeviceError)?.failure ?? .unexpected(String(describing: error)), false)
        }
    }

    /// Said at the door of something sent after the check before it, when it may not be sent
    /// (`DeviceLink.mayBeSent`): what that check heard in place of the recorder saying which it is, in the
    /// recorder's words, or else that the app is not connected.
    private func sayWhyNotSent(on link: DeviceLink) {
        if let heard = link.heardInstead {
            link.owner?.problem = heard.explanation
        } else {
            link.owner?.sayNotConnected()
        }
    }

    /// The same for an operation whose result says it, handed back for the result. What the check heard is the
    /// recorder's own answer and goes on the line as well, as a television's check puts it there; that the app
    /// is not connected is said in the result alone.
    private func whyNotSent(on link: DeviceLink) -> String {
        guard let heard = link.heardInstead else { return whyNotConnected }
        link.owner?.problem = heard.explanation
        return heard.explanation
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

private extension OperationFailure {
    /// What the link said of it on the line, for a result to say again; nil for what the link says nothing of
    /// there, a check's no and a device let go of.
    var sentence: String? {
        switch self {
        case .refused(_, let sentence), .silentAfterSending(let sentence), .silentOnARead(let sentence): sentence
        case .notSent, .letGoMeanwhile: nil
        }
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
