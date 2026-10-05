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
    /// The USB disk it records to, as an attach last read it, or as a round sent since has seen it: there
    /// or away, with no sizes.
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
/// `cancel`, `update`, `sendWhatWaits`, `reserve`, `resend`): the steps, what each can come to, and the
/// sentence said for it, through the link this is the driver of and that link's host. It is asked of the
/// driver alone, which is handed no link: with its link gone nothing is sent. The app keeps what comes back.
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
    ///
    /// An attach that fails says why on the host's line, but for one: silence, where the line is what a
    /// create or a delete that met silence left there. Silence is said once (`takesSilenceOnARead`). That
    /// sentence says the request may have arrived, which is all the reader has to go by until the television
    /// answers, and that the television is silent still adds nothing to it. An attach that goes through
    /// clears the line.
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
            let saidAlready = deviceError?.failure == .silent
                && [Self.createMetSilence, Self.mayHaveArrived].contains(owner?.problem)
            if !saidAlready, !quiet || !link.session.unreachable {
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

    /// What pulling the list down asks for, when the television can be asked: what waits is sent, and then
    /// the list is read now, as `reservations` reads it, so that what was just made is in it. When it cannot,
    /// the reader has asked for it to be tried again: a connect, which tells the host when it reaches the
    /// television (`reached`), and nil -- the host reads the list from there, inside the connect, and what a
    /// connect that got nowhere has to say is on its line.
    public func refreshReservations() async -> [Reservation]? {
        guard let link else { return nil }
        guard canBeAsked(on: link) else {
            await link.connect()
            return nil
        }
        // Through the host, as an attach asks for it: the host says what became of it.
        await link.owner?.sendWhatWaits()
        // A sending that lost the television, or its registration, has said so: a read would write over that.
        guard canBeAsked(on: link) else { return nil }
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
    /// Why nothing is sent while the disk a television records to is away: the client's own sentence, for
    /// the screens to say while a reservation waits for the disk to come back (`facts.storage`).
    public static let diskNotFound = ScalarClient.diskNotFound

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

    /// The flush, on the link's client as it stands now, with what stopped its round said and what it saw
    /// of the disk written down. Whether the television can be asked is asked again here, in the turn the
    /// client is read: the queue was read since the door, and a connect begun meanwhile has put a client of
    /// its own in the link, which has yet to hear which television answers it. The flush reads the queue
    /// afresh once it has its turn, so one that set out only to drop what is over can come to send a row
    /// the reader has just freed: its stop is said too.
    ///
    /// `only` and `consenting` are the queue's own (`PendingQueue.flush`), for a row the reader asked to have
    /// sent: with neither, as a sending of what waits passes them, every row goes and none with a consent.
    private func flush(_ store: GuideStore, on link: DeviceLink, only: String? = nil,
                       consenting: [String: String] = [:]) async -> PendingQueue.Outcome? {
        guard canBeAsked(on: link), let client = link.client as? ScalarClient else { return nil }
        let outcome = await PendingQueue.flush(client: client, store: store, consenting: consenting, only: only)
        say(stopped: outcome.stopped, on: link)
        noteTheDisk(seenBy: outcome)
        return outcome
    }

    /// What a round that stopped is said as, through the link, as any failure after the attach is. Silence at
    /// the request that makes a reservation has a sentence of its own and is always said, the television
    /// lost: the reservation may have been made. Silence at one of the round's reads is said as any read's.
    /// A cookie the television does not take is said in its own words and put down at once (`note`), the
    /// television kept. A disk that is away and answers that say nothing are no fault of the link's:
    /// neither the link nor its line of what went wrong is touched, and the rows go by themselves at a
    /// later sending. That the disk is away is said from what is known of the television instead
    /// (`noteTheDisk`), for as long as a reservation waits for it, and not as something that went wrong.
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

    /// Writes what a round saw of the disk into what is known of the television, both ways: the screens say
    /// the disk from there (`facts.storage`), and the attach that reads it may be a long way off in either
    /// direction -- the disk pulled out, or put back, under a television that stays connected.
    ///
    /// A round that stopped for want of the disk leaves it away. One that got past its opening while it
    /// was known as away leaves it there, with its sizes unknown until an attach reads them: a round
    /// reads the disk before anything else, and a row is made, found there, turned down or passed over
    /// only past that read. Any other round says nothing of the disk: one that asked the television
    /// nothing, having only rows to hold or to drop, and one that stopped at its opening for something
    /// else. A disk known as there is left as the attach read it, sizes and all.
    private func noteTheDisk(seenBy round: PendingQueue.Outcome) {
        if case .cannotRecord? = round.stopped {
            facts.storage = TVStorage(mounted: false, freeMB: nil, totalMB: nil)
        } else if facts.storage?.mounted == false,
                  !(round.sent + round.alreadyThere + round.refused + round.deferred).isEmpty {
            facts.storage = TVStorage(mounted: true, freeMB: nil, totalMB: nil)
        }
    }

    // MARK: - reserving a programme

    /// The line on screen while a reservation the reader has just asked for is made.
    public static let reservingLine = "テレビに予約を登録中"
    /// Said of a reservation kept on the phone because the television could not be asked: not connected,
    /// given up on, or silent to what a round reads before it sends anything.
    public static let waitsNotConnected = "テレビに接続していないため、予約を端末に保存しました。"
        + "次にテレビが答えたときに登録します。予約タブで削除できます。"
    /// Said of one kept because the television wants the app registered with it again.
    public static let waitsForTheRegistration = "テレビの登録が必要なため、予約を端末に保存しました。"
        + "登録すると送ります。"
    /// Said of one kept because the disk the television records to is away: it goes by itself once the
    /// disk is back.
    public static let waitsForTheDisk = "録画用の USB HDD が見つからないため、予約を端末に保存しました。"
        + "HDD が見つかったあと、テレビが答えたときに登録します。"
    /// Said of one kept because the television's answers said nothing that reads. It ends as the sentence
    /// for silence at a create does, the same thing following: the next sending reads the television's list
    /// before it sends anything.
    public static let waitsUnanswered = "テレビの応答を読み取れなかったため、予約を端末に保存しました。"
        + "次にテレビが答えたときに一覧で確かめ、届いていなければ送ります。"
    /// Said of a reservation the television's list held already. Nothing was made, and what is held is the
    /// television's own: it is taken for there already unless it is known to be less than was asked.
    public static let foundThere = "テレビにはこの番組の予約がすでにありました。"
    /// Said of a programme whose end has passed: it is neither made nor kept.
    public static let programmeIsOver = "この番組は放送が終わっているため、予約していません。"
    /// Said when the reservation is no longer in the phone's queue and the television's list does not show
    /// it either: nothing says whether it was made.
    public static let couldNotBeConfirmed = "予約を登録できたか確かめられませんでした。予約タブで確かめてください。"

    /// Reserves `program` on the television, in DR: what a television records in, and what the waiting row
    /// then shows. What it came to, and the television's list where one was read afterwards, for the caller
    /// to keep (nil when none was read) -- as `cancel` hands its list back.
    ///
    /// The driver makes nothing by itself. The reservation is written to the phone's queue and the queue is
    /// asked to send that one row, so that the question before a create, the list after it, silence and
    /// every reason are the round's own rules here, as they are when what waits is sent. No consent is
    /// handed in: a reservation that would stop another from recording is held with the reason that names
    /// it, and making it all the same is the reader's to ask for, by sending the row again.
    ///
    /// Turned away at the door, with nothing kept, nothing sent and no line -- the sentence is in the result,
    /// and what an earlier operation left on the line stays (`Reserved`): the link gone; a repeat a
    /// television is not sent for this programme (`TVReservationBody.repeatType`), and with it a repeat or a
    /// kind of broadcast the tables do not know, which no programme of the guide has; a programme whose end
    /// has passed; and a queue that cannot be opened or written to.
    ///
    /// The row is written before anything is asked: whatever becomes of the asking, the reservation is
    /// kept. It replaces one already waiting for the same programme on the television, its reason with it.
    /// A television that cannot be asked is then sent nothing and is not connected to: the row goes with the
    /// next sending of what waits. So do the other rows waiting for the television, which are not sent
    /// here: the result is about one reservation, and another row's trouble does not keep this one from
    /// being asked about.
    public func reserve(_ program: GuideProgramRow,
                        repeating: String) async -> (reserved: Reserved, list: [Reservation]?) {
        guard let link else { return (.notDone(Self.notConnected), nil) }
        guard let request = ReservationRequest(program: program, quality: "DR", repeating: repeating),
              TVReservationBody.repeatType(for: request.repeatCode, start: request.start) != nil else {
            return (.notDone(ScalarClient.repeatNotTaken), nil)
        }
        // After the repeat, which is settled without the clock. A round would drop such a row; with no
        // round it would be kept, and promised to a television that is never sent it.
        guard request.end >= Date() else { return (.notDone(Self.programmeIsOver), nil) }
        guard let store = link.owner?.cache else { return (.notDone(PendingQueue.noCache), nil) }
        // Queued at a whole second, as the cache keeps the moment: the row handed back is the row that waits.
        let queuedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let row = PendingReservation(request: request, serviceName: program.serviceName, queuedAt: queuedAt,
                                     target: ScalarClient.slot)
        do {
            try await store.queue(row)
        } catch {
            return (.notDone(PendingQueue.couldNotBeKept(error)), nil)
        }
        let sent = await sendOne(row, under: Self.reservingLine, on: link, from: store)
        return (await came(row, sent, from: store), sent.list)
    }

    /// What a round for one row, and the list read after it, hand back: nil for a round that never ran, and
    /// for a list that was not read.
    private typealias OneSent = (round: PendingQueue.Outcome?, list: [Reservation]?)

    /// One waiting row sent because the reader asked for that reservation, which is all that reserving a
    /// programme and sending a row again have in common: the line, the check, the flush of that row alone
    /// with its consent, and the list afterwards.
    ///
    /// A television that cannot be asked is sent nothing and no line goes up: what is done about that is the
    /// caller's, before this. Otherwise the line goes up before the check, as any operation's does, and stays
    /// until the list has been read. No round runs when the check says no -- the line of what went wrong is
    /// then the check's -- or when the door fails in the turn the client is read (`flush`).
    ///
    /// `reason` is the sentence the reader consented to, for a row held for what it would stop from
    /// recording, and nil for no consent. It goes to the queue with the row's id, and is held there against
    /// the reason the row carries in the turn it is sent.
    ///
    /// The list is read when the round did not leave the row waiting or drop it as over, and while the
    /// television can still be asked: after a row that was made or found there, so that the caller has the
    /// list with the reservation in it; and after a round that had the row in none of its lists with nothing
    /// stopped, where the list is all that says what became of it (`reserved`). After anything else nothing
    /// is read. Silence at a create is followed by no request at all, and a read that goes through clears
    /// the line of what went wrong, which a reservation that was not made is not to do.
    private func sendOne(_ row: PendingReservation, consentingTo reason: String? = nil, under line: String,
                         on link: DeviceLink, from store: GuideStore) async -> OneSent {
        guard canBeAsked(on: link) else { return (nil, nil) }
        return await link.underALine(line) { _ -> OneSent in
            let consenting = reason.map { [row.id: $0] } ?? [:]
            guard case .up = await link.check(),
                  let round = await self.flush(store, on: link, only: row.id, consenting: consenting) else {
                return (nil, nil)
            }
            let waitsOrIsOver = round.refused + round.held + round.deferred + round.expired
            guard round.stopped == nil, !waitsOrIsOver.contains(where: { $0.id == row.id }),
                  self.canBeAsked(on: link) else { return (round, nil) }
            return (round, await self.read(link, underALine: false))
        }
    }

    /// What a round for one row came to, as the result of reserving it: the one place that reads a round so,
    /// a round that never ran included. The first of these that fits:
    ///
    /// - No round ran: kept, to go when the television can next be asked, which for one that wants the app
    ///   registered is once it is.
    /// - The round made the row: made, with what the television's list showed the create did beyond its
    ///   own row. One row was sent, so every remark of the round is this one's.
    /// - The round found it in the television's list: made, and said to have been there already.
    /// - Refused now, or held with a reason from before: kept with that reason on it. The reason for what
    ///   it would stop from recording is told apart, so that whoever asked need not read a sentence to know
    ///   it is a question for the reader and no refusal.
    /// - Dropped because its programme was over: neither made nor kept.
    /// - Passed over, or the round stopped at it: kept with no reason, and what stopped the round says in
    ///   which sentence.
    ///
    /// A row in none of the round's lists, with nothing stopped, was not in the queue when the round came to
    /// it: another sending took it first, the reader deleted it, or the queue could not be read. Its absence
    /// is not read as made. The answer is taken from the television's list as read after the round (`list`)
    /// and from nothing else: a recording of the programme there that is all the row asks for is made; one
    /// that falls short of its repeat is said in the reason for that (`ScalarClient.shortfall`); and with
    /// none listed, or no list read, nothing is known to have been made. Where the queue could not be read
    /// the row waits still: `came` looks for it there, and answers for it, before this is asked.
    func reserved(_ row: PendingReservation, by round: PendingQueue.Outcome?, listing list: [Reservation]?,
                  now: Date = Date()) -> Reserved {
        guard let round else {
            return .waiting(row, saying: facts.needsPairing ? Self.waitsForTheRegistration : Self.waitsNotConnected)
        }
        func has(_ rows: [PendingReservation]) -> Bool { rows.contains { $0.id == row.id } }
        if has(round.sent) {
            return .made(saying: round.remarks.isEmpty ? nil : round.remarks.joined(separator: "。"))
        }
        if has(round.alreadyThere) { return .made(saying: Self.foundThere) }
        if let kept = (round.refused + round.held).first(where: { $0.id == row.id }), let reason = kept.problem {
            return ScalarClient.holdsForWhatItWouldStop(reason) ? .wouldStop(kept) : .waiting(kept, saying: reason)
        }
        if has(round.expired) { return .notDone(Self.programmeIsOver) }
        if has(round.deferred) { return .waiting(row, saying: Self.waitsUnanswered) }
        switch round.stopped {
        case .silent(afterSending: true)?: return .waiting(row, saying: Self.createMetSilence)
        case .silent(afterSending: false)?: return .waiting(row, saying: Self.waitsNotConnected)
        case .needsPairing?: return .waiting(row, saying: Self.waitsForTheRegistration)
        case .cannotRecord?: return .waiting(row, saying: Self.waitsForTheDisk)
        case .saysNothing?: return .waiting(row, saying: Self.waitsUnanswered)
        case nil: break
        }
        if let held = list?.compactMap(\.tvRow).holding(row.request) {
            return ScalarClient.shortfall(of: held, for: row.request).map { .notDone($0) } ?? .made(saying: nil)
        }
        return .notDone(row.request.end < now ? Self.programmeIsOver : Self.couldNotBeConfirmed)
    }

    /// What one row sent because the reader asked for that reservation came to, which is how reserving a
    /// programme and sending a row again both end. `row` is the row as it waits now: for one sent again,
    /// with its reason gone where that was taken off.
    ///
    /// With no round the row was not sent (`notSent`). A round is read as `reserved` reads it, but for an
    /// empty one. A round for one row that has it in none of its lists, with nothing stopped, is an empty
    /// one, and that is all a round shows whose own read of the queue failed. So the queue is read once
    /// more before the list is taken for the answer: a row that waits still is said to wait, and not to be
    /// neither made nor kept because the television's list does not have what was never sent. With no
    /// reason on it, it goes by itself, and the next sending reads the television's list first. One that
    /// still carries a reason -- the one the reader consented to, in a round that then asked nothing about
    /// the row -- is held as it was, and is answered as a row that was not sent.
    private func came(_ row: PendingReservation, _ sent: OneSent, from store: GuideStore) async -> Reserved {
        guard let round = sent.round else { return notSent(row) }
        if round == PendingQueue.Outcome(slot: ScalarClient.slot),
           let waits = (try? await store.pendingReservations())?.first(where: { $0.id == row.id }) {
            return waits.problem == nil ? .waiting(waits, saying: Self.waitsUnanswered) : notSent(waits)
        }
        return reserved(row, by: round, listing: sent.list)
    }

    /// What a waiting row is answered as when nothing could be asked about it: the television is not one
    /// that can be asked, or did not answer the check before the round. One with no reason goes when the
    /// television can next be asked, and is said so (`reserved`). One with a reason on it waits for the
    /// reader whatever the television does next: it is handed back with its reason, and what is said is why
    /// it was not sent, in the two sentences a delete says at its own door (`cancel`). It is never said to
    /// go by itself.
    private func notSent(_ row: PendingReservation) -> Reserved {
        guard row.problem != nil else { return reserved(row, by: nil, listing: nil) }
        return .waiting(row, saying: facts.needsPairing ? ScalarError.notRegistered.explanation : Self.notConnected)
    }

    // MARK: - sending a waiting row again

    /// Sends a row waiting for the television again, as the reader asked on that row. What its round came
    /// to, for the host to say as it says any sending -- nil when none ran; the television's list where one
    /// was read afterwards, for the caller to keep, as `reserve` hands it back; and what the row came to,
    /// for the screen the reader asked on to say -- nil where there is nothing for it to say.
    ///
    /// A row that is not the television's is refused before anything else, as `cancel` refuses another
    /// device's reservation: nothing is read, sent, written or said for it. With the link or the cache gone
    /// any row is refused the same way. Nothing is said at this door, and nothing is handed back to say
    /// (`Reserved`).
    ///
    /// The row is read again from the queue, since the one handed in is the row as a screen drew it. One
    /// that has gone is left at that. What becomes of the reason goes by the reason the queue has now:
    ///
    /// - The reason for what the reservation would stop from recording stays on the row, and sending the
    ///   row again is the reader's consent to it: to that sentence. What is handed to the queue is the
    ///   sentence on the row the reader pressed, which is held there against the reason the row carries in
    ///   the turn it is sent, and by the television against what it names then (`ScalarClient.send`). Where
    ///   the queue's reason is already another than the one pressed, nothing is sent and nothing changed:
    ///   the reader has not seen what they would be consenting to, and the host reads the queue again.
    /// - Any other reason is taken off, so that the row goes with the rest from now on. No consent is
    ///   handed in for such a row, whatever a sending writes on it next.
    ///
    /// A television that cannot be asked is connected to: the reader asked. That connect's attach sends
    /// what waits, a row just freed with it, and this ends with the connect, as sending a recorder's row
    /// again does. An attach sends nothing that is held for what it would stop. Such a row is sent from
    /// here once the connect has made the television one that can be asked, and otherwise stays held.
    ///
    /// A consent is for one round. A row that went in with one and that the round left unsettled -- passed
    /// over, or the round stopped before the television had answered about it -- has its reason taken off.
    /// Kept, the reason would hold the row back from every later sending, while what is said of such a row
    /// is that it goes by itself: after silence at its create, that the next sending looks for it in the
    /// television's list. It is then asked about afresh, with no consent. A row the round held with a
    /// reason written anew keeps that reason, and so does one whose consent no longer stood in its turn.
    ///
    /// What the row came to is about the row as it waits now, its reason gone where it was taken off
    /// here, before the round or after it. A round is read as a reservation's is (`came`). Where no round
    /// answers for the row:
    ///
    /// - Turned away at the door, or no longer in the queue: nil.
    /// - The queue's reason is no longer the one pressed: that it would stop others from recording, with
    ///   the row as the queue has it, for a screen to ask about the names as they are now.
    /// - Left to the connect made here: what the queue shows of the row once that connect is over
    ///   (`leftToTheConnect`), nil where its sending took the row out.
    /// - Held for what it would stop and not sent after all, the television still not one that can be
    ///   asked: the row with its reason, and why it was not sent (`notSent`).
    public func resend(_ waiting: PendingReservation) async
        -> (round: PendingQueue.Outcome?, list: [Reservation]?, came: Reserved?) {
        guard waiting.target == ScalarClient.slot, let link, let store = link.owner?.cache else {
            return (nil, nil, nil)
        }
        guard var row = (try? await store.pendingReservations())?.first(where: { $0.id == waiting.id }) else {
            return (nil, nil, nil)
        }
        var consent: String?
        if let reason = row.problem, ScalarClient.holdsForWhatItWouldStop(reason) {
            guard reason == waiting.problem else { return (nil, nil, .wouldStop(row)) }
            // The sentence the reader pressed on, not the one just read: what a consent is to.
            consent = waiting.problem
        } else if row.problem != nil, (try? await store.setPendingProblem(row.id, nil)) != nil {
            row.problem = nil
        }
        if !canBeAsked(on: link) {
            await link.connect()
            guard consent != nil else { return (nil, nil, await leftToTheConnect(row, on: link, from: store)) }
        }
        let sent = await sendOne(row, consentingTo: consent, under: Self.sendingLine, on: link, from: store)
        if consent != nil, let round = sent.round,
           round.stopped != nil || round.deferred.contains(where: { $0.id == row.id }),
           (try? await store.setPendingProblem(row.id, nil)) != nil {
            row.problem = nil
        }
        return (sent.round, sent.list, await came(row, sent, from: store))
    }

    /// What a row came to that `resend` left to the connect it made. The row had no consent to go with, so
    /// that connect's own sending took it with the rest, and what that sending came to is the host's to
    /// say, as any connect's is. What is left to answer the reader with is read from the queue, once, by
    /// the row's name:
    ///
    /// - Gone: nil. That sending made it, found it there or dropped it as over, and the host says which.
    ///   Nil too where the queue cannot be read, and nothing is known of the row.
    /// - There with a reason: that sending wrote it. The reason for what the reservation would stop from
    ///   recording is a question for the reader, about names no screen has shown them yet; any other is
    ///   said as it stands.
    /// - There with none, and the television still cannot be asked: it goes when the television can be,
    ///   as a reservation kept for such a television is said to (`reserved`).
    /// - There with none, and the television can be asked: the connect got through, and its sending left
    ///   the row all the same. For want of the disk, where the attach or that sending has just read it as
    ///   away; otherwise for answers that said nothing that reads. Not for want of a connection, which
    ///   there is.
    private func leftToTheConnect(_ row: PendingReservation, on link: DeviceLink,
                                  from store: GuideStore) async -> Reserved? {
        guard let waits = (try? await store.pendingReservations())?.first(where: { $0.id == row.id }) else {
            return nil
        }
        if let reason = waits.problem {
            return ScalarClient.holdsForWhatItWouldStop(reason) ? .wouldStop(waits) : .waiting(waits, saying: reason)
        }
        guard canBeAsked(on: link) else { return reserved(waits, by: nil, listing: nil) }
        let diskIsAway = facts.storage?.mounted == false
        return .waiting(waits, saying: diskIsAway ? Self.waitsForTheDisk : Self.waitsUnanswered)
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
