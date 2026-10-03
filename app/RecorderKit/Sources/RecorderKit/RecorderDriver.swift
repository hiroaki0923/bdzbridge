import Foundation

/// What is particular to a BDZ recorder in a link: it is woken by a magic packet and waited for, found at another
/// address by the MAC at the end of its UDN, recognised by that UDN, and read on every attach for its firmware,
/// its MAC and its free space, which are only shown or kept and must not fail the attach. The runs with no screen,
/// which have no link, make their attempt here too (`reachWithNoScreen`, `isTheOneKnown`).
@MainActor
public final class RecorderDriver: LinkDriver {
    /// Not read yet: the recorder's operations are still the app's, and will be asked of this on its link.
    public weak var link: DeviceLink?
    /// Written on each reservation that was waiting when another recorder took the place of the one it was made
    /// for (`GuideStore.claim`).
    private let heldForAnotherRecorder: String
    /// How long the screens wait for the recorder to answer after the packet, and how often they ask meanwhile.
    private let wakingLimit: TimeInterval
    private let wakingInterval: Duration
    /// How long a client waits before sending again what the recorder answered 503 (`RecorderClient`).
    private let busyRetryDelay: ClosedRange<Double>

    /// The waking's limit and interval, and the pause before a 503 is sent again, are given only by the tests,
    /// which have no seconds to wait.
    public init(holdingTheQueueWith reason: String, wakingLimit: TimeInterval = Waking.screenLimit,
                wakingInterval: Duration = .seconds(1), busyRetryDelay: ClosedRange<Double> = 0.5...1) {
        heldForAnotherRecorder = reason
        self.wakingLimit = wakingLimit
        self.wakingInterval = wakingInterval
        self.busyRetryDelay = busyRetryDelay
    }

    /// Short: a recorder that has left the network says nothing rather than refuse, and a patient timeout is
    /// half a minute of silence before anything is done about it.
    public var probeTimeout: TimeInterval { RecorderClient.probeTimeout }

    public var noAnswerLine: String { RecorderError.transport("no answer").explanation }

    public func makeClient(for link: DeviceLink) -> any LinkClient {
        RecorderClient(host: link.host, transport: link.environment.transport(link.host),
                       busyRetryDelay: busyRetryDelay)
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
    /// firmware, the MAC and the free space are read too, but another model may refuse one or answer in a shape
    /// of its own, and that must not fail the attach: what cannot be read is left unknown. Silence still ends it.
    /// What waits is sent last, and an attach that met silence there has not reached anything to show.
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
            link.session.answered()
            owner?.problem = nil
            await owner?.sendWhatWaits()
            // The recorder can go quiet in the middle of sending the queue, which leaves the app offline like any
            // other silence; a connect that ended there has not reached anything to show.
            guard !link.session.unreachable else { return false }
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
        if inMemory == .another { owner?.anotherDeviceDescribedItself(wasConnected: wasConnected) }
        // The demo's cache is a file of its own, made for the invented recorder and deleted with it.
        guard let owner, !owner.isDemo, let store = owner.cache else { return true }
        // What the session knows goes with it: a cache with no owner written is the last recorder's when the lists
        // were.
        let lastWasAnother = inMemory == .another
        let onDisk: Recognition
        do {
            onDisk = try await store.claim(for: recorder, holdingTheQueueWith: heldForAnotherRecorder,
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
