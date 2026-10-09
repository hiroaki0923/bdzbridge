import Foundation
import Observation

/// The client a link asks a device through: what the link itself reads of it, beside the probe.
public protocol LinkClient: DeviceEndpoint {
    /// The address it asks. Readable without waiting on the actor, for a caller deciding whether this is the
    /// client for the address it wants.
    nonisolated var host: String { get }
    /// When the device last answered anything at all, or nil. How long it has been quiet says whether to make
    /// sure of it before asking (`LinkRules.needsCheck`).
    var lastAnswer: Date? { get }
}

extension RecorderClient: LinkClient {}

/// What a link reaches beyond the device itself: the network the phone is on, and what it may put on the local
/// network by itself. The app's are the real ones, except in the demo and in its tests, where nothing goes on
/// the LAN; a test of the link hands it its own.
@MainActor
public struct LinkEnvironment {
    /// How requests reach a device at an address.
    public var transport: (_ host: String) -> any HTTPTransport
    /// Which network the phone is on, as far as whether to try a device again goes (`LocalNetwork.signature`).
    public var networkSignature: () -> String
    /// Sends a magic packet to `mac` for the device at `host`. Nothing acknowledges it.
    public var sendPacket: (_ mac: String, _ host: String) -> Void
    /// Whether local network privacy is why the device at `host` said nothing. False when it is not to be asked.
    public var lanIsBlocked: (_ host: String) async -> Bool
    /// The addresses to look through for a device that has moved from `host`: none when it is not to be looked
    /// for at all.
    public var hostsNear: (_ host: String) -> [String]
    /// Looks through `hosts` for the recorder whose UDN ends with `mac`.
    public var findRecorder: (_ mac: String, _ hosts: [String]) async -> RecorderDescription?
    /// Looks through `hosts` for the television whose MAC is `mac`, and gives its address. Nothing is looked
    /// for unless it is given: a link with no television to follow has no use for it.
    public var findTelevision: (_ mac: String, _ hosts: [String]) async -> String?
    /// How long after an attach found the recorder's USB slot answering no disk, while one was known, the slot is
    /// read again: the driver's minute (`RecorderDriver.slotReadAgainAfter`), unless a test, which has no minute
    /// to wait, gives less.
    public var slotReadAgainAfter: Duration
    /// How long the slot is waited for before something that names it is sent while it has not answered the disk
    /// known since the recorder last answered (`RecorderDriver.settleTheSlot`), and in the queue's round of the
    /// clients the link makes: the driver's ten seconds, unless a test gives less.
    public var slotSettling: SlotSettling

    public init(transport: @escaping (_ host: String) -> any HTTPTransport,
                networkSignature: @escaping () -> String,
                sendPacket: @escaping (_ mac: String, _ host: String) -> Void,
                lanIsBlocked: @escaping (_ host: String) async -> Bool,
                hostsNear: @escaping (_ host: String) -> [String],
                findRecorder: @escaping (_ mac: String, _ hosts: [String]) async -> RecorderDescription?,
                findTelevision: @escaping (_ mac: String, _ hosts: [String]) async -> String? = { _, _ in nil },
                slotReadAgainAfter: Duration = RecorderDriver.slotReadAgainAfter,
                slotSettling: SlotSettling = .afterAWaking) {
        self.transport = transport
        self.networkSignature = networkSignature
        self.sendPacket = sendPacket
        self.lanIsBlocked = lanIsBlocked
        self.hostsNear = hostsNear
        self.findRecorder = findRecorder
        self.findTelevision = findTelevision
        self.slotReadAgainAfter = slotReadAgainAfter
        self.slotSettling = slotSettling
    }
}

/// What a link tells the app, and asks of it: the lines on the screen, what the phone keeps, and the lists the
/// app holds of what the device said. Called on the main actor at fixed points of an attempt. What is not
/// `async` happens in the same turn as what caused it, and some of it has to: the lists another device's
/// description makes stale go before any screen gets a turn over them.
@MainActor
public protocol LinkHost: AnyObject, Sendable {
    /// The one line that says what went wrong.
    var problem: String? { get set }
    func beginActivity(_ text: String) -> Activities.Token
    func updateActivity(_ token: Activities.Token, to text: String)
    func endActivity(_ token: Activities.Token)
    /// Something is under way that a second client would only get in the way of.
    var isBusy: Bool { get }
    /// A bulk job holds the client it started with: no connect starts beside it.
    var holdsOffConnect: Bool { get }
    /// The invented device of the demo is in play.
    var isDemo: Bool { get }
    /// The phone's cache of what the device said, once opened.
    var cache: GuideStore? { get }
    /// Opens the cache before an attempt reaches the device -- what waits is sent from it, and who answers is
    /// measured against it -- and lets go of what the last connect was to read again.
    func cacheForAttempt() async
    /// An address the device answered at, or was set to: written down for the runs with no screen.
    func keepAddress(_ host: String)
    /// The MAC the device reported, kept for waking it, with the address it was read at.
    func keepMAC(_ text: String)
    /// Where the MAC kept was read, or nil when nobody knows.
    var macReadAt: String? { get }
    /// The MAC kept was read from the device now at `host`.
    func macWasReadAt(_ host: String)
    func forgetMac()
    /// Another device has described itself where the last one was: what the app holds of the last one goes, in
    /// this turn. `wasConnected` says whether it was connected to the last one when this one answered.
    func anotherDeviceDescribedItself(wasConnected: Bool)
    /// The cache has been made over to another device: what the screens show of it is read again.
    func cacheMadeOver() async
    /// Another device answered and the cache could not be made over to it: the app is not connected over it.
    func cacheCouldNotBeMadeOver()
    /// Sends what waits for this device, and says what became of it. A driver asks for it from inside its
    /// attach, and a television's again when its list is pulled down, before the list is read.
    func sendWhatWaits() async
    /// The phone's queue may have changed -- the driver has written it, or is about to send from it: what the
    /// screens show of it is to be read again.
    func queueWritten() async
    /// A connect reached the device: the reads that follow one, inside the connect.
    func reached() async
    /// The check before an operation heard another device where this one was. What was asked is not sent.
    func anotherAnsweredTheCheck()
    /// Nothing could be asked: the app is not connected. Says why.
    func sayNotConnected()
    /// Local network privacy is in the way at `host`: wait for the permission, and say so.
    func waitForPermission(at host: String)
    func stopWaitingForPermission()
}

/// What a link asks of the kind of device it is about: how to make a client, wake one, find one that has moved,
/// and read one as it answers. The recorder's is `RecorderDriver`, a television's `TVDriver`. A driver belongs
/// to one link, which it holds: what the app asks of a device after its attach is asked of the driver alone.
@MainActor
public protocol LinkDriver: AnyObject, Sendable {
    /// The link this is the driver of, set by the link as it is made.
    var link: DeviceLink? { get set }
    /// How long the first ask of an attempt, and the check before an operation, wait.
    var probeTimeout: TimeInterval { get }
    /// What is said when the check before an operation met silence and nothing could be done about it.
    var noAnswerLine: String { get }
    /// Whether a read that has just met silence loses the device and says so (`DeviceLink.say`). Silence on
    /// something that changes the device always does, whatever this answers.
    func takesSilenceOnARead(_ link: DeviceLink) -> Bool
    func makeClient(for link: DeviceLink) -> any LinkClient
    /// Whether there is something to wake the device with. A failure on the first ask is kept off the screen
    /// when there is, since the waking that follows is the answer to it.
    func canWake(_ link: DeviceLink) -> Bool
    /// Sends the packet that wakes the device, when there is one to send.
    func sendPacket(_ link: DeviceLink)
    /// Reads what the device says about itself and what goes with it, and sends what waits. True when the
    /// attempt reached it. `what` is the line on screen, nil inside something that has said what it is doing.
    func attach(_ link: DeviceLink, client: any LinkClient, what: String?, timeout: TimeInterval?,
                quiet: Bool) async -> Bool
    /// Wakes the device and attaches once it answers.
    func wakeAndAttach(_ link: DeviceLink, client: any LinkClient) async -> Bool
    /// Looks for the device at another address and attaches there: nil when it answered there, `.silent` when
    /// it was not found or not looked for.
    func findElsewhere(_ link: DeviceLink) async -> DeviceFailure?
    /// The check before an operation's ask: why it failed, if it did, and whether another device answered.
    func check(_ link: DeviceLink, client: any LinkClient) async -> (failure: DeviceFailure?, stranger: Bool)
}

/// Why a device is not up for what the reader asked for: what the check before an operation found
/// (`DeviceLink.check`). With any of these, nothing has been sent.
public enum NotUp: Sendable, Equatable {
    /// No client, or the last ask met silence: the app is not connected. The host has said so
    /// (`sayNotConnected`).
    case notConnected
    /// Silence because local network privacy stopped the ask. The app waits for the permission. The line of
    /// what went wrong was cleared, not written: the screens say this from the session (`connectBlocked`).
    case waitingForPermission
    /// Another device answered where the one in play was, on the probe or after a waking. The host has been
    /// told (`anotherAnsweredTheCheck`).
    case anotherAnswered
    /// Silent to the probe, woken, and the attach that followed was turned away: busy, a fault, not a
    /// recorder. It is there and not given up on, and the attach has said why. An attach its host broke off
    /// -- over a cache that could not be made over, the device let go of -- ends here as well, the host
    /// having said why: the two are not told apart.
    case turnedAway
    /// Nothing answered, the waking included. The link is lost (`lost`), and the line is the waking's own
    /// sentence, or the driver's `noAnswerLine` where there was nothing to wake the device with.
    case silent
}

/// What the check before an operation found: the client to ask, or why nothing is to be asked.
public enum LinkCheck: Sendable {
    case up(any LinkClient)
    case notUp(NotUp)

    /// What a check that ended in `why` is to whoever asked it with `client` in hand.
    fileprivate init(_ why: NotUp?, asking client: any LinkClient) {
        self = why.map(Self.notUp) ?? .up(client)
    }
}

/// The app's connection to one device: when it is asked, woken, made sure of and given up on, and when it is
/// asked again -- on coming back to the app, when the network changes, when the local network permission comes.
/// The decisions are `LinkRules`'s and the order of an attempt is `Reach`'s; what is particular to the kind of
/// device is its driver's, and what is the app's -- the screens' lines and lists, what the phone keeps -- is
/// told to its owner. The rules are set out in docs/porting.md (端末側の設計メモ). The app's tests hold them, and
/// `DeviceLinkTests` those that need the local network to be seen at work.
@MainActor
@Observable
public final class DeviceLink {
    /// The device's address. Written down by the owner whenever it is set, for the runs with no screen.
    public var host: String {
        didSet { owner?.keepAddress(host) }
    }
    /// What is known of the device and of the link to it, for the screens to read.
    public let session: SessionState
    /// The client of the attempt under way or the last one. Nil when the device has been let go of.
    public var client: (any LinkClient)?
    /// The client whose attach went through: the one that has heard which device answers it, and so the one that
    /// may be asked what needs that. Every attempt makes a client of its own (`reach`), which is `client` from
    /// before its first ask and has yet to hear who answers; it becomes this when its driver says so, part way
    /// through an attach -- once the device has said which it is and what goes with that has been read, before
    /// what waits is sent, so that what is asked from inside the attach passes. An attempt that fails before then
    /// never becomes it, and leaves the last one here; one that fails after, sending what waits or reading on,
    /// stays it, and what the session says of the device stands beside it. Weak: this is not what keeps a client
    /// alive. Nil once the device has been let go of (`forgetTheDevice`).
    @ObservationIgnored public internal(set) weak var attachedClient: (any LinkClient)?

    /// Whether the client in hand is the one whose attach went through (`attachedClient`).
    public var clientIsAttached: Bool { client != nil && client === attachedClient }

    /// What the check before an operation heard in place of the device saying which it is: a refusal, a fault, an
    /// answer that does not read -- from the device, or from whatever has taken its address. Nil until then, and
    /// again once a check or an attach hears the device say which it is; the driver's check and its attach write
    /// it (`TVDriver.check`). While it is set nothing is sent that is for the device known alone (`mayBeSent`),
    /// and an operation makes its check whatever the time since the address last answered (`checksAgain`): an
    /// answer that does not say which device gave it says nothing of the device asked next. Not observed.
    @ObservationIgnored public internal(set) var heardInstead: (any DeviceError)?

    /// Whether the check before an operation is made however lately the address answered: the last check heard
    /// something in place of the device saying which it is (`heardInstead`).
    public var checksAgain: Bool { heardInstead != nil }

    /// Whether what is for the device known alone may be sent, read after the check before an operation has
    /// answered: the client in hand is the one whose attach went through (`clientIsAttached`), the session is
    /// connected, and the last check heard the device say which it is (`heardInstead`). A driver adds what is
    /// its own to it (`TVDriver`: no registration wanted).
    public var mayBeSent: Bool { clientIsAttached && session.connected && heardInstead == nil }
    /// The check before an operation that is out, so that everything asked for while it runs waits for its
    /// answer -- and is given its reason -- rather than sending a probe, and a magic packet, of its own. Nil
    /// from it when the device is up.
    public private(set) var wakeCheck: Task<NotUp?, Never>?
    /// A read the driver has left for later (`readLater`), while it waits or is out; nil otherwise. It goes with
    /// the device: when another describes itself and when the device is let go of (`endTheReadLeftForLater`).
    /// The app leaving ends it too, and a return that makes no attach leaves it for later again
    /// (`setTheReadLeftForLaterAside`).
    @ObservationIgnored public private(set) var readLeftForLater: Task<Void, Never>?
    /// What that read is, how long it was to wait and what it does, while there is one.
    @ObservationIgnored private var leftForLater: (delay: Duration, read: @MainActor (DeviceLink) async -> Void)?
    /// The read the app's leaving ended, kept for its return; nil once the return has taken it up, or anything
    /// else has ended the reads left for later.
    @ObservationIgnored private var setAside: (delay: Duration, read: @MainActor (DeviceLink) async -> Void)?
    /// Counts the reads left for later, so that one that has ended does not take the place of the next.
    @ObservationIgnored private var readsLeftForLater = 0
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored public weak var owner: (any LinkHost)?
    @ObservationIgnored public let driver: any LinkDriver
    @ObservationIgnored public var environment: LinkEnvironment

    /// Writes nothing: `host` is the address as saved, or the demo's. The driver is told whose it is, and is
    /// to be no other link's.
    public init(host: String, session: SessionState, driver: any LinkDriver, environment: LinkEnvironment) {
        self.host = host
        self.session = session
        self.driver = driver
        self.environment = environment
        driver.link = self
    }

    /// True while there is no point asking the device anything: nothing has been set up, or the last ask got
    /// silence.
    public var offline: Bool { client == nil || session.unreachable }

    /// Whether the phone is on a network the last attempt was not made on.
    public var networkChanged: Bool { session.networkChanged(now: environment.networkSignature()) }

    // MARK: - connecting

    /// Connects, waking the device first if that is what it needs. Not beside another connect or a bulk job --
    /// two clients would be two conversations with a device that answers the second with 503 -- and a check
    /// already waking this device is waited for rather than started again.
    public func connect() async {
        guard !host.isEmpty, !session.connecting, !(owner?.holdsOffConnect ?? false) else { return }
        if let wakeCheck, let client, client.host == host {
            _ = await wakeCheck.value
            return
        }
        session.beginConnecting()
        defer { session.endConnecting() }
        // This attempt answers what a wait for the permission was waiting to find out, one way or the other.
        owner?.stopWaitingForPermission()
        await owner?.cacheForAttempt()
        guard var reached = await reach() else { return }
        // The network can change while a connect is under way -- the Wi-Fi joined on the way in through the door
        // -- and the looks at the network keep out of a connect's way. So a connect that got nowhere tries once
        // more when the network it started on is no longer the one under it.
        if LinkRules.triesOnceMore(reached: reached, networkChanged: networkChanged) {
            guard let again = await reach() else { return }
            reached = again
        }
        // Only silence is given up on: a device that answered, if only to refuse, is there.
        session.finishedTrying(reached: reached)
        // Inside the connect: the screens count it as under way until what follows has been read.
        if reached { await owner?.reached() }
    }

    /// One attempt at the device, in the order `Reach.run` keeps: a client of its own, the packet, the first
    /// probe, the permission, the waking, and a look at another address. Whether it answered, or nil when local
    /// network privacy is why it did not and the app is waiting for the permission instead.
    private func reach() async -> Bool? {
        let client = driver.makeClient(for: self)
        self.client = client
        let outcome = await Reach.run(Reach.Steps(
            sendPacket: {
                self.driver.sendPacket(self)
                self.session.tried(on: self.environment.networkSignature())
            },
            probe: {
                await self.driver.attach(self, client: client, what: "接続中", timeout: self.driver.probeTimeout,
                                         quiet: self.driver.canWake(self)) ? nil : self.whyNotAttached
            },
            blocked: { await self.environment.lanIsBlocked(self.host) },
            wake: {
                // The permission was not why, or was not asked about: either way nothing is waiting on it.
                self.session.permissionCleared()
                return await self.driver.wakeAndAttach(self, client: client) ? nil : self.whyNotAttached
            },
            elsewhere: { await self.driver.findElsewhere(self) }))
        if outcome == .blocked {
            waitForPermission()
            return nil
        }
        session.permissionCleared()
        return outcome == .answered
    }

    /// Why the attach that has just failed did, as `Reach` asks it: silence, or something that answered.
    public var whyNotAttached: DeviceFailure {
        session.unreachable ? .silent : .refused(reason: owner?.problem ?? "")
    }

    /// Silence because the system stopped the app asking, not because the device is asleep: the packet could not
    /// leave either. The app waits for the permission instead, given up until it comes.
    private func waitForPermission() {
        session.waitingForPermission()
        owner?.problem = nil
        owner?.waitForPermission(at: host)
    }

    /// The wait for the permission at `host` has ended: allowed, or not. The one exception to leaving a device
    /// alone until the network changes or the reader asks -- allowing it is the reader asking.
    public func permissionArrived(_ allowed: Bool, at host: String) async {
        session.permissionCleared()
        if allowed, self.host == host { await connect() }
    }

    /// Leaves the app where a connect that got no answer leaves it: not connected, given up until the network
    /// changes or the reader asks. Every request that meets silence comes here. Where the app tried is left as it
    /// was; when the network did move meanwhile, the looks that followed its report are set going again.
    public func lost() {
        session.lost()
        if session.link.sawAnotherNetwork { networkReported() }
    }

    /// Lets go of the device as far as memory goes: what it said of itself, which it was, and the client, the one
    /// whose attach went through among them. A wait for the permission at it ends too.
    public func forgetTheDevice() {
        session.forgotTheDevice()
        client = nil
        attachedClient = nil
        endTheReadLeftForLater()
        owner?.stopWaitingForPermission()
    }

    // MARK: - a read left for later

    /// Runs `read` once `delay` has gone by, in a task of the link's own that holds the link only while `read`
    /// runs: a link let go of goes, and the read with it. One at a time, a second taking the first's place. It
    /// does not hold back whatever is under way, and nothing waits for it.
    public func readLater(after delay: Duration, _ read: @escaping @MainActor (DeviceLink) async -> Void) {
        endTheReadLeftForLater()
        readsLeftForLater += 1
        let this = readsLeftForLater
        leftForLater = (delay, read)
        readLeftForLater = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled, let self { await read(self) }
            if let self, self.readsLeftForLater == this {
                self.readLeftForLater = nil
                self.leftForLater = nil
            }
        }
    }

    /// Ends the read left for later, if there is one: one still waiting is not made, and one that is out is
    /// cancelled, which the driver's read takes as the word to leave its answer. One set aside for the app's
    /// return goes too: whatever ended this knows better.
    public func endTheReadLeftForLater() {
        readLeftForLater?.cancel()
        readLeftForLater = nil
        leftForLater = nil
        setAside = nil
    }

    /// The app is leaving: the read left for later is ended, as `endTheReadLeftForLater` ends it, since made after
    /// a return it would come beside the return's own reads. It is kept for that return, which leaves it for later
    /// again when it makes no attach (`returned`): what the read was to settle would otherwise stay unsettled for as
    /// long as the reader comes back inside the minute in which a return does not connect (`LinkRules.onReturn`).
    public func setTheReadLeftForLaterAside() {
        let left = leftForLater
        endTheReadLeftForLater()
        setAside = left
    }

    // MARK: - making sure before an operation

    /// Makes sure the device is up before something the reader asked for is sent to it, and wakes it if it is
    /// not. The client to ask, or why nothing is to be asked. Asked first and briefly, with the client already
    /// in hand, which is the one handed back. `evenIfRecent` asks whatever the time since the last answer, for
    /// when the network has changed since.
    ///
    /// What a check tells the host on the way -- that another device answered, the wait for the permission,
    /// the sentence of a silence -- it tells once, however many were waiting for its answer. That the app is
    /// not connected is said to each who asks.
    public func check(evenIfRecent: Bool = false) async -> LinkCheck {
        guard let client, !offline else {
            owner?.sayNotConnected()
            return .notUp(.notConnected)
        }
        // Already at it: a connect, or the waking of an earlier check -- whose attach reads lists of its own
        // through here, and must not wait for itself.
        if session.connecting || session.waking { return .up(client) }
        if let wakeCheck { return LinkCheck(await wakeCheck.value, asking: client) }
        let check = Task { await self.makeSureItIsUp(client, evenIfRecent: evenIfRecent) }
        wakeCheck = check
        let why = await check.value
        if wakeCheck == check { wakeCheck = nil }
        return LinkCheck(why, asking: client)
    }

    /// The check as a Bool: whether the device is there to ask.
    public func ensureUp(evenIfRecent: Bool = false) async -> Bool {
        if case .up = await check(evenIfRecent: evenIfRecent) { return true }
        return false
    }

    /// The check itself. Nil when the device is up.
    private func makeSureItIsUp(_ client: any LinkClient, evenIfRecent: Bool) async -> NotUp? {
        if !LinkRules.needsCheck(lastAnswer: await client.lastAnswer, now: Date(), evenIfRecent: evenIfRecent) {
            return nil
        }
        // Where it was asked, not where the phone is once the silence is over: see `lost`.
        let network = environment.networkSignature()
        // Who is being made sure of: what the reader asked for must not go to another that answers in its place.
        let known = session.device
        var stranger = false
        var answeredTheProbe = true
        // The packet first and the probe after, as connecting does. Not looked for at another address from here.
        let outcome = await Reach.run(Reach.Steps(
            sendPacket: { self.driver.sendPacket(self) },
            probe: {
                let answer = await self.driver.check(self, client: client)
                if answer.stranger { stranger = true }
                if answer.failure == .silent {
                    // Silence, which is what waking is for.
                    answeredTheProbe = false
                    self.session.wentSilent(on: network)
                }
                return answer.failure
            },
            blocked: { await self.environment.lanIsBlocked(self.host) },
            wake: { await self.driver.wakeAndAttach(self, client: client) ? nil : self.whyNotAttached }))
        switch outcome {
        case .answered:
            // Another device answers where the one in play was -- on the probe, or after a waking, whose attach
            // has turned the app to it already.
            if stranger || (known != nil && session.device != known) {
                owner?.anotherAnsweredTheCheck()
                return .anotherAnswered
            }
            return nil
        case .refused:
            // On the probe: something answered, so what is wrong is for the request itself to say, or for the
            // driver, which may send nothing on the strength of it (`TVDriver.check`). After the waking: it
            // answered only to refuse, which the attach has said already.
            return answeredTheProbe ? nil : .turnedAway
        case .blocked:
            waitForPermission()
            return .waitingForPermission
        case .silent:
            lost()
            // Waking says why it gave up; without a way to wake it there was no waking to say it.
            if !driver.canWake(self) { owner?.problem = driver.noAnswerLine }
            return .silent
        }
    }

    // MARK: - asking again

    /// The app is active again after `wasAway`: what that is worth is `LinkRules.onReturn`'s to say.
    public func returned(wasAway: Bool, busy: Bool) async {
        let hasAddress = !host.isEmpty, checking = wakeCheck != nil
        // The last answer is on the client's actor: asked only where the rule will read it.
        let asksItsAge = wasAway && hasAddress && !busy && !checking && session.connected
        let lastAnswer = asksItsAge ? await client?.lastAnswer : nil
        // The read the leaving set aside is left for later again, from now. A return that attaches ends it, the
        // attach reading afresh what the read was for, and one whose connect makes another client has it ask
        // nothing (`RecorderDriver.readTheSlotAgain`); so it is made only after a return that made no attach.
        if let left = setAside { readLater(after: left.delay, left.read) }
        switch LinkRules.onReturn(wasAway: wasAway, hasAddress: hasAddress, busy: busy, checking: checking,
                                  connected: session.connected, lastAnswer: lastAnswer, now: Date(),
                                  gaveUp: session.gaveUp, networkChanged: networkChanged) {
        case .nothing: return
        case .lookAtTheNetwork: networkReported()
        case .connect: await connect()
        }
    }

    /// A report that the network changed, which is news of the network but not yet the network: the address
    /// can arrive after it. So the network is looked at again for a while (`LinkRules.looksAfterAReport`),
    /// until something has been done about it.
    public func networkReported() {
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
        session.noted(network: environment.networkSignature())
    }

    /// One look at the network: another network makes another attempt worth making unasked, and makes the last
    /// answer worth nothing while connected. Whether an attempt was made, or the device made sure of.
    @discardableResult
    public func networkChangedWhileOpen() async -> Bool {
        // Noted first, busy or not.
        noteTheNetwork()
        switch LinkRules.onNetworkChange(hasAddress: !host.isEmpty, busy: owner?.isBusy ?? false,
                                         networkChanged: networkChanged, connected: session.connected) {
        case .nothing:
            return false
        case .connect:
            // A connect returns without trying while another or a job is under way; whether it tried is what
            // the count says.
            let before = session.link.tries
            await connect()
            return session.link.tries != before
        case .makeSure:
            session.tried(on: environment.networkSignature())
            _ = await ensureUp(evenIfRecent: true)
            return true
        }
    }
}
