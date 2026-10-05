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
/// What is asked of a television after its attach is here as well (`reservations`, `refreshReservations`,
/// `cancel`, `update`, `sendWhatWaits`): the steps, what each can come to, and the sentence said for it,
/// through the link this is the driver of and that link's host. It is asked of the driver alone, which is
/// handed no link: with its link gone nothing is sent. The app keeps what comes back.
@MainActor
public final class TVDriver: LinkDriver {
    public let facts = TVFacts()
    /// The link holds the driver, so weak. Each operation reads it once, as it is asked for, and goes through
    /// on the link it found there.
    public weak var link: DeviceLink?
    private let credentials: any TVCredentialStore
    /// What the television lists the app as, among the devices registered with it.
    private let nickname: String
    /// Whether the app is in front, the only place a renewal is asked for. A television that no longer lists
    /// the app turns one down in standby and shows nothing (error 40005, seen minutes after it was switched
    /// off), but with its display on it puts a PIN on the screen. So the reader is to be there. One that lists
    /// the app renewed in standby with nothing shown, more than five hours after it was switched off as well.
    private let inFront: @MainActor () -> Bool
    /// The read of the reservations that is out, which whoever asks meanwhile waits for.
    private var reading: Task<[Reservation]?, Never>?
    /// The client that has heard which television answers it and that its cookie is taken: the one that may
    /// be asked what needs the registration. Every attempt at the television makes a client of its own, and
    /// until its attach has got that far nothing is asked on the strength of the last one's. An attach that
    /// got that far and then met silence sending what waits leaves this set, and the television still cannot
    /// be asked: its session is lost (`canBeAsked`).
    private weak var attachedClient: ScalarClient?

    public init(credentials: any TVCredentialStore, nickname: String, inFront: @escaping @MainActor () -> Bool) {
        self.credentials = credentials
        self.nickname = nickname
        self.inFront = inFront
    }

    public var probeTimeout: TimeInterval { 5 }

    public var noAnswerLine: String { ScalarError.transport("no answer").explanation }

    /// Only while the session is still connected: silence is said once, so that a read which waited its turn
    /// behind the request that met it does not write over what that one said -- a delete that may have arrived.
    public func takesSilenceOnARead(_ link: DeviceLink) -> Bool { link.session.connected }

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
    /// found: another television may be at the address by now, and the cookie is not for it. Never with the
    /// link gone.
    public var canBeAsked: Bool { link.map { canBeAsked(on: $0) } ?? false }

    private func canBeAsked(on link: DeviceLink) -> Bool {
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
    /// Said when a change to a television's reservation is asked for, which nothing here makes yet (`update`).
    public static let changesNotYet = "テレビの予約の変更は、このアプリではまだできません。"
    /// For the host to say when nothing could be asked because the app is not connected (`sayNotConnected`).
    public static let notConnected = "テレビに接続していません。テレビの電源とネットワーク接続を確認してください。"

    /// What the television is set to record, read now: nil when it could not be read, and the host's line
    /// says why. A television that cannot be asked is sent nothing and nothing is said of it: the screens ask
    /// this as they appear, and the line an earlier operation left is not theirs to write over.
    public func reservations() async -> [Reservation]? {
        guard let link, canBeAsked(on: link) else { return nil }
        return await read(link)
    }

    /// What pulling the list down asks for: the list read now, as `reservations` reads it, when the
    /// television can be asked. When it cannot, the reader has asked for it to be tried again: a connect,
    /// which tells the host when it reaches the television (`reached`), and nil -- the host reads the list
    /// from there, inside the connect, and what a connect that got nowhere has to say is on its line.
    public func refreshReservations() async -> [Reservation]? {
        guard let link else { return nil }
        if canBeAsked(on: link) { return await read(link) }
        await link.connect()
        return nil
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

    /// The read itself, as one operation through the link (`DeviceLink.run`): under a line of its own unless
    /// it is a step of something that has one, the television made sure of first -- inside a connect that
    /// answers at once -- and a read that goes through clears the line of what went wrong, as any operation
    /// does. How it failed the link says; what that tells of the registration is kept here (`note`).
    ///
    /// It is sent on the link's client, read once the check has answered, as it was before the read went
    /// through the link, and not on the one `run` hands over, which was in hand as the check was asked. No
    /// way was found for the two to differ at one address -- a connect asked for while a check is out waits
    /// for it and makes no client -- and the read is left as it was all the same. A reminder to watch is no
    /// reservation and is left out (`TVScheduleRow.reservation`).
    private func readNow(_ link: DeviceLink, underALine: Bool) async -> [Reservation]? {
        let read = await link.run(line: underALine ? Self.readingLine : nil) { _ in
            try await (link.client as? ScalarClient)?.schedules().compactMap { $0.reservation() }
        }
        switch read {
        case .success(let list):
            return list
        case .failure(let failure):
            note(failure)
            return nil
        }
    }

    /// What a request sent after the attach failed as, where the screens read it: told apart and said by the
    /// link (`OperationFailure.init`, `DeviceLink.say`), and noted here. It is said as a read's is, in the
    /// television's own words: silence met by what changes the television has a sentence of its own, which
    /// the operation that sent it says itself (`cancel`).
    private func say(_ error: any Error, on link: DeviceLink) {
        note(link.say(OperationFailure(error, sending: nil)))
    }

    /// What the driver keeps of a failure the link has said. A refusal for want of a registration is put down
    /// at once: the app was taken off the television's list while the link stood, the next attach may be a
    /// long way off, and the screens are to ask for the registration now; the next attach that goes through
    /// takes it back.
    private func note(_ failure: OperationFailure) {
        if case .refused(.needsPairing, _) = failure { facts.needsPairing = true }
    }

    /// Takes a reservation off the television. Whether it was deleted, and the freshest list read on the way
    /// for the caller to keep, nil when none was read.
    ///
    /// A reservation that is not a television's is refused before anything else: nothing is read, sent or
    /// said for it. It is another device's to delete, and looked for here it could only be taken for a row
    /// of the television's. With the link gone any reservation is refused the same way.
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
    /// the app has let go of that link meanwhile: the link is read once, here, and held to the end. Two
    /// cancels of one reservation at once would each send their delete; the screens hold the second back
    /// while the first is out (the host's `isBusy`).
    public func cancel(_ reservation: Reservation) async -> (deleted: Bool, list: [Reservation]?) {
        guard reservation.device == .tv, let link else { return (false, nil) }
        let owner = link.owner
        guard canBeAsked(on: link) else {
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

    /// Changes nothing: nothing here changes a television's reservation yet. Nothing is read and nothing
    /// sent, and the line says so, since the reader asked for the change. What is handed back has the shape a
    /// change will have: whether it was made, and the freshest list read on the way, which here is none. A
    /// reservation that is not a television's is refused as `cancel` refuses it, with nothing said.
    public func update(_ reservation: Reservation, quality: String,
                       repeating: String) async -> (changed: Bool, list: [Reservation]?) {
        guard reservation.device == .tv else { return (false, nil) }
        link?.owner?.problem = Self.changesNotYet
        return (false, nil)
    }

    // MARK: - what waits in the queue

    /// The line on screen while what waits for the television is sent.
    public static let sendingLine = "テレビに送信待ちの予約を登録中"
    /// Said when the request that makes a waiting reservation met silence: it may have been made all the same,
    /// so it is not sent again, and the next sending reads the television's list before it sends anything.
    public static let createMetSilence = "送信の途中でテレビの応答がなくなりました。届いている場合もあるため、"
        + "送り直していません。次にテレビが答えたときに一覧で確かめ、届いていなければ送ります。"

    /// Sends what waits in the phone's queue for the television. What the sending came to, or nil when none
    /// ran.
    ///
    /// A television that cannot be asked is sent nothing, and nothing is read or said: what waits goes with
    /// the next attach. The queue is looked at before the television is. With nothing in it to send -- no row
    /// of the television's, or only rows with a reason on them, which wait for the reader -- nothing is asked
    /// and no line goes up: a row held back would otherwise put the line up at every connect for as long as
    /// it waited. Rows whose programmes are over are still dropped, which asks the television nothing.
    ///
    /// Otherwise the rows go under a line of their own, the television made sure of first -- inside a connect
    /// that answers at once. No consent is handed in: a row held for what it would stop from recording waits
    /// for the reader, though the television would give the very same reason now.
    ///
    /// Written on the link's parts and not through `DeviceLink.run`, which clears the line of what went
    /// wrong whenever its work returns. A flush always returns, with a round that stopped as well, and a
    /// sending leaves that line as it was unless what stopped the round is the link's to say (`say(stopped:on:)`).
    public func sendWhatWaits() async -> PendingQueue.Outcome? {
        guard let link, canBeAsked(on: link), let store = link.owner?.cache else { return nil }
        let now = Date()
        let rows = ((try? await store.pendingReservations()) ?? []).filter { $0.target == ScalarClient.slot }
        guard PendingQueue.hasSomethingToSend(rows, for: ScalarClient.slot, now: now) else {
            guard rows.contains(where: { $0.request.end < now }) else { return nil }
            return await flush(store, on: link)
        }
        return await link.underALine(Self.sendingLine) { _ -> PendingQueue.Outcome? in
            guard case .up = await link.check() else { return nil }
            return await self.flush(store, on: link)
        }
    }

    /// The flush, on the link's client as it stands now, and what stopped its round said. Whether the
    /// television can be asked is asked again here, in the turn the client is read: the queue was read since
    /// the door, and a connect begun meanwhile has put a client of its own in the link, which has yet to hear
    /// which television answers it. The flush reads the queue afresh once it has its turn, so one that set
    /// out only to drop what is over can come to send a row the reader has just freed: its stop is said too.
    private func flush(_ store: GuideStore, on link: DeviceLink) async -> PendingQueue.Outcome? {
        guard canBeAsked(on: link), let client = link.client as? ScalarClient else { return nil }
        let outcome = await PendingQueue.flush(client: client, store: store)
        say(stopped: outcome.stopped, on: link)
        return outcome
    }

    /// What a round that stopped is said as, through the link, as any failure after the attach is. Silence at
    /// the request that makes a reservation has a sentence of its own and is always said, the television
    /// lost: the reservation may have been made. Silence at one of the round's reads is said as any read's.
    /// A cookie the television does not take is said in its own words and put down at once (`note`), the
    /// television kept. A disk that is away and answers that say nothing are no fault of the link's, and
    /// nothing here has a line for them: neither the link nor the line is touched, and the rows go by
    /// themselves at a later sending.
    private func say(stopped stop: SendingStop?, on link: DeviceLink) {
        switch stop {
        case .silent(afterSending: true)?:
            _ = link.say(.silentAfterSending(sentence: Self.createMetSilence))
        case .silent(afterSending: false)?:
            _ = link.say(.silentOnARead(sentence: noAnswerLine))
        case .needsPairing?:
            note(link.say(.refused(.needsPairing, sentence: ScalarError.notRegistered.explanation)))
        case .cannotRecord?, .saysNothing?, nil:
            break
        }
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
