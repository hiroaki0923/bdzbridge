import Foundation
import Observation

/// What a television said of itself, for the screens: kept by its driver rather than in `SessionState`, which
/// holds what every device has. Nil and false until the television has said.
@MainActor
@Observable
public final class TVFacts {
    /// The model, as `getInterfaceInformation` gives it.
    public internal(set) var model: String?
    /// Set when the television answers but takes no cookie of the app's: it is to be registered again.
    public internal(set) var needsPairing = false
    /// The USB disk it records to, as last read.
    public internal(set) var storage: TVStorage?

    public init() {}
}

/// What is particular to a Sony BRAVIA in a link. It is asked whether it is on (`getPowerStatus`, which it
/// answers in standby) and never woken: one that does not answer could only be sent a magic packet, which may
/// light it, and the app does not light it unasked. It is told from any other by the MAC it wakes on. An attach
/// reads that, its model, and its USB disk -- the read that needs a registration, so the one that says whether
/// there is one -- and renews the cookie when it is past half its life.
///
/// What is asked of a television after its attach is here as well (`reservations`, `cancel`): the steps, what
/// each can come to, and the sentence said for it, through the link and the link's host. The app keeps what
/// comes back.
@MainActor
public final class TVDriver: LinkDriver {
    public let facts = TVFacts()
    private let credentials: any TVCredentialStore
    /// What the television lists the app as, among the devices registered with it.
    private let nickname: String
    /// Whether the app is in front, the only place a renewal is asked for. A television that no longer lists
    /// the app turns one down in standby and shows nothing (error 40005), but with its display on it puts a PIN
    /// on the screen; and none has been tried on a television hours into standby. So the reader is to be there.
    private let inFront: @MainActor () -> Bool
    /// The read of the reservations that is out, which whoever asks meanwhile waits for.
    private var reading: Task<[Reservation]?, Never>?
    /// The client whose attach went through: the one that may be asked what needs the registration. Every
    /// attempt at the television makes a client of its own, which has yet to hear which television answers it
    /// and whether the cookie is taken; until its attach is through, nothing is asked on the strength of the
    /// last one's -- and an attempt that fails never becomes this.
    private weak var attachedClient: ScalarClient?

    public init(credentials: any TVCredentialStore, nickname: String, inFront: @escaping @MainActor () -> Bool) {
        self.credentials = credentials
        self.nickname = nickname
        self.inFront = inFront
    }

    public var probeTimeout: TimeInterval { 5 }

    public var noAnswerLine: String { ScalarError.transport("no answer").explanation }

    public func makeClient(for link: DeviceLink) -> any LinkClient {
        ScalarClient(host: link.host, transport: link.environment.transport(link.host), credentials: credentials)
    }

    public func canWake(_ link: DeviceLink) -> Bool { false }

    public func sendPacket(_ link: DeviceLink) {}

    // MARK: - attaching

    /// The first ask needs no registration: the MAC that says which television this is. Then the model, which is
    /// only shown, and the USB disk, which needs the registration: a television that refuses it answered, so it
    /// is there and is not given up on, but nothing can be asked of it until it is registered again. What waits
    /// is sent last, as a recorder's attach does.
    public func attach(_ link: DeviceLink, client: any LinkClient, what: String? = "接続中",
                       timeout: TimeInterval? = nil, quiet: Bool = false) async -> Bool {
        guard let client = client as? ScalarClient else { return false }
        let owner = link.owner
        // A line that says which device, beside the recorder's own 接続中 when both connect at once.
        var activity: Activities.Token?
        if what != nil { activity = owner?.beginActivity(Self.connectingLine) }
        defer { if let activity { owner?.endActivity(activity) } }
        do {
            let identity = (try await client.wakeOnLANAddress(timeout: timeout)).flatMap(WakeOnLan.normalise) ?? ""
            guard link.session.recognises(identity: identity) != .another else {
                // Its cookie would not be good here, and what waits was made for the television registered.
                link.session.strangerAnswered()
                owner?.problem = Self.anotherAnswered
                return false
            }
            link.session.identified(as: identity)
            owner?.keepAddress(link.host)
            if !identity.isEmpty { owner?.keepMAC(identity) }
            if let model = try await RecorderError.silenceOnly({ try await client.interface().modelName }),
               !model.isEmpty {
                facts.model = model
            }
            facts.storage = try await client.storage()
            facts.needsPairing = false
            attachedClient = client
            if inFront(), credentials.load()?.renewalDue(now: Date()) == true {
                // A renewal that fails costs nothing: the cookie in hand is still good.
                _ = try await RecorderError.silenceOnly { try await client.renew(nickname: nickname) }
            }
            link.session.answered()
            owner?.problem = nil
            await owner?.sendWhatWaits()
            guard !link.session.unreachable else { return false }
            link.session.attached()
            return true
        } catch {
            let deviceError = error as? any DeviceError
            if deviceError?.failure == .needsPairing { facts.needsPairing = true }
            link.session.attachFailed(deviceError?.failure)
            if !quiet || !link.session.unreachable {
                owner?.problem = deviceError?.explanation ?? String(describing: error)
            }
            return false
        }
    }

    public static let connectingLine = "テレビに接続中"

    /// Said when the device at the television's address is another one.
    public static let anotherAnswered = "登録したテレビとは別の機器が応答しました。設定の「テレビ」から追加し直してください。"

    /// Never: see the type's description.
    public func wakeAndAttach(_ link: DeviceLink, client: any LinkClient) async -> Bool { false }

    /// Not looked for at another address yet.
    public func findElsewhere(_ link: DeviceLink) async -> DeviceFailure? { .silent }

    // MARK: - after the attach

    /// Whether what needs the registration can be asked: the television answered the last time, takes the
    /// app's cookie, and the client in the link is the one it answered. The first two both, since an attach
    /// that ended in a 403 leaves the session connected: the television said which it is before it refused. The
    /// third because a connect under way has a client of its own and the session still says what the last one
    /// found: another television may be at the address by now, and the cookie is not for it.
    public func canBeAsked(_ link: DeviceLink) -> Bool {
        guard let attachedClient, link.session.connected, !facts.needsPairing else { return false }
        return (link.client as? ScalarClient) === attachedClient
    }

    /// The lines on screen while the reservations are read and while one is deleted: they say which device,
    /// beside the recorder's own.
    public static let readingLine = "テレビの予約一覧を取得中"
    public static let deletingLine = "テレビの予約を削除中"

    /// Said when a reservation to delete is not in the list just read. Not that it was deleted: all that is
    /// seen is that the television lists nothing under its id.
    public static let notInList = "この予約はテレビの予約一覧に見つかりませんでした。一覧を更新しました。"
    /// Said when the id is listed and is no longer the reservation held (`TVTarget.changed`).
    public static let listChanged = "テレビ側で予約が更新されていました。一覧を更新したので、もう一度お試しください。"
    /// Said when a delete met silence. Whether it arrived is not known, which is why it is not sent again.
    public static let mayHaveArrived = "送信の途中でテレビの応答がなくなりました。届いている場合もあるため、"
        + "送り直していません。再接続してから一覧で確かめてください。"
    /// Said when the television answers that it has no such reservation and goes on listing it.
    public static let deleteRefused = "テレビが削除を受け付けませんでした（41200）。"
    /// Said by the app when it is asked to change a television's reservation, which nothing here does yet.
    public static let changesNotYet = "テレビの予約の変更は、このアプリではまだできません。"

    /// What the television is set to record, read now: nil when it could not be read, and the host's line
    /// says why. A television that cannot be asked is sent nothing and nothing is said of it: the screens ask
    /// this as they appear, and the line an earlier operation left is not theirs to write over.
    public func reservations(on link: DeviceLink) async -> [Reservation]? {
        guard canBeAsked(link) else { return nil }
        return await read(link)
    }

    /// One read at a time. The list is asked for when a screen appears, when it is pulled down and when the
    /// television has just been connected to, and these come together: whoever asks while a read is out gets
    /// its answer, and no second request is sent. One still out when a delete has gone through was sent after
    /// that delete -- the client sends one request at a time -- so its answer shows it.
    private func read(_ link: DeviceLink, underALine: Bool = true) async -> [Reservation]? {
        if let reading { return await reading.value }
        let read = Task {
            defer { self.reading = nil }
            return await self.readNow(link, underALine: underALine)
        }
        reading = read
        return await read.value
    }

    /// The read itself, under a line of its own unless it is a step of something that has one. The television
    /// is made sure of first -- inside a connect that answers at once -- and a read that goes through clears
    /// the line of what went wrong, as any operation does. A reminder to watch is no reservation and is left
    /// out (`TVScheduleRow.reservation`).
    private func readNow(_ link: DeviceLink, underALine: Bool) async -> [Reservation]? {
        let owner = link.owner
        let line = underALine ? owner?.beginActivity(Self.readingLine) : nil
        defer { if let line { owner?.endActivity(line) } }
        guard await link.ensureUp(), let client = link.client as? ScalarClient else { return nil }
        do {
            let rows = try await client.schedules()
            owner?.problem = nil
            return rows.compactMap { $0.reservation() }
        } catch {
            say(error, on: link)
            return nil
        }
    }

    /// What a request sent after the attach failed as, where the screens read it. Silence leaves the link as
    /// any silence does, given up until the network changes or the reader asks; it is said once, so that a
    /// request which waited its turn behind the one that met it does not write over what that one said -- a
    /// delete that may have arrived. A refusal for want of a registration is put down at once: the app was
    /// taken off the television's list while the link stood, the next attach may be a long way off, and the
    /// screens are to ask for the registration now; the next attach that goes through takes it back. Anything
    /// else is the television's own to say.
    private func say(_ error: any Error, on link: DeviceLink) {
        let deviceError = error as? any DeviceError
        switch deviceError?.failure {
        case .silent:
            guard link.session.connected else { return }
            link.lost()
            link.owner?.problem = noAnswerLine
        case .needsPairing:
            facts.needsPairing = true
            link.owner?.problem = deviceError?.explanation
        default:
            link.owner?.problem = deviceError?.explanation ?? String(describing: error)
        }
    }

    /// Takes a reservation off the television. Whether it was deleted, and the freshest list read on the way
    /// for the caller to keep, nil when none was read.
    ///
    /// A television that cannot be asked is sent nothing, and here the line says why: the reader asked for
    /// this. Otherwise the list is read first and the reservation found in it (`tvTarget`): the row sent is
    /// the one just read, and a reservation that has gone, or whose id is now another's, is not written to. A
    /// read that fails sends nothing. The delete is sent once. Silence there may be a delete that arrived, so
    /// nothing is sent after it and the row stays listed until a read says otherwise. An answer that the
    /// television has no such reservation (41200) is settled by reading again. After a delete that went
    /// through the list is read once more, and the row is taken out of whatever comes back: a television a
    /// moment behind itself must not bring it back, and the delete counts though that read fails.
    ///
    /// The reads on the way go under the delete's line, not one of their own. When making sure of the
    /// television ends at the local network permission, the reason is on the session (`connectBlocked`) and
    /// not on the line. Asked for by the reader, a delete is carried through on the link it began on though
    /// the app has let go of that link meanwhile. Two cancels of one reservation at once would each send their
    /// delete; the screens hold the second back while the first is out (the host's `isBusy`).
    public func cancel(_ reservation: Reservation,
                       on link: DeviceLink) async -> (deleted: Bool, list: [Reservation]?) {
        let owner = link.owner
        guard canBeAsked(link) else {
            if facts.needsPairing {
                owner?.problem = ScalarError.notRegistered.explanation
            } else {
                owner?.sayNotConnected()
            }
            return (false, nil)
        }
        let line = owner?.beginActivity(Self.deletingLine)
        defer { if let line { owner?.endActivity(line) } }
        guard await link.ensureUp(), let client = link.client as? ScalarClient,
              let list = await read(link, underALine: false) else { return (false, nil) }
        let target = list.tvTarget(of: reservation)
        guard case .found(let listed) = target, let row = listed.tvRow else {
            owner?.problem = target == .gone ? Self.notInList : Self.listChanged
            return (false, list)
        }
        do {
            try await client.deleteSchedule(row)
        } catch let error as any DeviceError where error.failure == .silent {
            link.lost()
            owner?.problem = Self.mayHaveArrived
            return (false, list)
        } catch let error as any DeviceError where error.failure == .unknownItem {
            // The read comes first: one that goes through clears the line, and one that fails has said why.
            guard let newer = await read(link, underALine: false) else { return (false, list) }
            owner?.problem = newer.contains { $0.id == row.id } ? Self.deleteRefused : Self.notInList
            return (false, newer)
        } catch {
            say(error, on: link)
            return (false, list)
        }
        let after = await read(link, underALine: false) ?? list
        return (true, after.filter { $0.id != row.id })
    }

    // MARK: - the check before an operation

    public func check(_ link: DeviceLink, client: any LinkClient) async -> (failure: DeviceFailure?, stranger: Bool) {
        guard let client = client as? ScalarClient else { return (.unexpected("not a television's client"), false) }
        do {
            _ = try await client.powerStatus(timeout: probeTimeout)
            return (nil, false)
        } catch {
            return ((error as? any DeviceError)?.failure ?? .unexpected(String(describing: error)), false)
        }
    }
}
