import Foundation

/// What a night with no screen found, handed over as it finds it (`RecorderDriver.refreshWithNoScreen`) for the
/// app to tell: in notifications, and in the time the settings show.
public enum NightFound: Sendable {
    /// What waits was not sent, because the recorder that answered is not the one it was made for.
    case heldBack
    /// What became of what waited.
    case queue(PendingQueue.Outcome)
    /// What is told once, as the sending ends: the notice of reservations that have not reached the recorder
    /// in time, nil for none; whether the last such notice is to be taken away; and what has been told from
    /// now on, for the app to keep and hand to the next run (`ToldOnce.after`).
    case told(notYet: String?, withdraws: Bool, kept: ToldOnce)
    /// The internal disk's free space and size, in bytes, with its label while a USB disk beside it takes
    /// recordings.
    case freeSpace(free: Int, total: Int, naming: String?)
    /// The USB disk, when it takes recordings.
    case usbSpace(RecorderDisk)
    /// A guide was fetched, at this time.
    case fetched(Date)
}

/// Whether the recorder that answered a run with no screen is the one the phone's cache is of
/// (`RecorderDriver.isTheOneKnown`).
public enum TheOneKnown: Sendable, Equatable {
    /// The recorder the cache is of, or the first the cache has heard from.
    case yes
    /// Another recorder: it says which it is, and the cache is not its own.
    case another
    /// It cannot be told: the device did not describe itself, or whose cache this is could not be read. No
    /// other recorder is known to have answered, and it is not known to be the cache's own either.
    case cannotBeTold
}

/// What a run with no screen has to tell once of the recorder, beside what became of what waited: what the
/// rule the television's runs have (`ToldOnce.after`) comes to in the recorder's words (`NoScreenWords.recorder`).
public struct NoScreenTold: Sendable, Equatable {
    /// Whether it is news that another recorder answered and what waits was not sent: the stop told last was
    /// not this one, and no notice below carries it. With no next run handed in, whenever one answered.
    public var heldBackIsNews: Bool
    /// The notice of reservations that have not reached the recorder in time; nil for none.
    public var notYet: String?
    /// The last such notice is to be taken away: none of the reservations it told of waits to go any more.
    public var withdrawsNotYet: Bool
    /// What has been told from now on, for the app to keep; nil when nothing is to be written.
    public var kept: ToldOnce?

    public init(heldBackIsNews: Bool = false, notYet: String? = nil, withdrawsNotYet: Bool = false,
                kept: ToldOnce? = nil) {
        self.heldBackIsNews = heldBackIsNews
        self.notYet = notYet
        self.withdrawsNotYet = withdrawsNotYet
        self.kept = kept
    }
}

public extension NoScreenWords {
    /// The recorder's. Its rows; its own first sentence for the notice of reservations not yet there; in their
    /// way, another recorder, or the recorder not answering -- nobody reached, or a round that stopped at
    /// silence -- and otherwise nothing known, so that opening the app sends them; the one stop it has, another
    /// recorder, in the sentence the notification of a queue held back says; and of a round, what a round
    /// with no screen tells (`RecorderDriver.tells`), a late notice or none.
    static let recorder = NoScreenWords(
        slot: RecorderClient.slot,
        notYet: { RecorderDriver.notYetAtTheRecorder($0) },
        inTheWay: { RecorderDriver.inTheWay(after: $0) },
        stop: { _ in RecorderDriver.anotherAnsweredWithNoScreen },
        round: { outcome, device, _ in RecorderDriver.tells(outcome, naming: device) })
}

/// The recorder's runs with no screen -- the overnight run and the Shortcuts action -- which have no link: the
/// one attempt each makes at the recorder, whether the recorder that answered is the one known, the order of
/// each run, what each came to and what is said of it. The television's are in `TVNoScreen.swift`, and what a
/// sending came to is the same four for both (`NoScreenSending`). The app has the entries, sends the packet,
/// posts the notifications and keeps what is told.
extension RecorderDriver {
    // MARK: - reaching the recorder

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
    /// the recorder known and the guide would go into a cache that is still its own. Nor when it cannot be told
    /// -- an owner that cannot be read, a device that did not describe itself -- which is answered apart from
    /// another recorder: nothing is sent to it either, but no other recorder has answered as far as anybody
    /// knows, and none is to be said to have.
    public nonisolated static func isTheOneKnown(_ client: RecorderClient,
                                                 to store: GuideStore) async -> TheOneKnown {
        guard let answering = await client.info, let who = try? await store.recognises(answering) else {
            return .cannotBeTold
        }
        return who == .another ? .another : .yes
    }

    // MARK: - the overnight run

    /// The overnight run, with no screen behind it: the recorder is reached, woken if need be
    /// (`reachWithNoScreen`), what waits in the queue goes out while it is up, how much room is left is found
    /// out, and the guide is fetched, every type of it. Whether a programme was stored, by a run that told all
    /// it found. What it finds on the way is handed to `found` as it finds it, each waited for before the next
    /// step: what became of the queue and the free space are told before a guide download that can outlast the
    /// task.
    ///
    /// Silence ends the run where it is first met: whatever came next would wait the same silence out again, of
    /// a recorder that has gone. A round of what waits that met it is told, and nothing is asked after it. The
    /// slot's ends it with nothing told. The free space's ends it once the USB disk's space has been told, where
    /// the slot had answered a disk that takes recordings: that was heard before the silence, and telling it
    /// asks nothing. In the guide, that a guide was fetched is told when a type answered before the silence, what
    /// was stored before it is handed back, and nothing more is asked. A night whose one silence passed gives up
    /// what it had not come to -- the free space, the guide -- until the next connect or the next night.
    ///
    /// Nothing is handed over once the cache is another recorder's: the screens have taken one up while the run
    /// was out (`GuideStore.claim`), and what the run found is of a recorder that is theirs no longer. The store
    /// is asked again before each thing told from the round on (`isTheOneKnown`); once what became of the queue
    /// has been told, which is where the app posts its notification and can take a while; before the guide,
    /// where there may have been nothing to tell since the round; and once the guide's turn has come, which
    /// can be waited for as long as a refresh of the screens' takes (`GuideRefresh.run`), and where the task
    /// is looked at again as well. The run ends where the cache has become another's, and asks nothing more
    /// of the recorder the screens have left: turned away as its guide's turn comes, it has asked for no
    /// file. So it does after a guide that such a cache ended, having taken nothing of a file
    /// (`GuideRefresh.Stop.letGo`): that a guide was fetched is not told, and nothing is handed back as
    /// stored, the make-over having taken away what was. An owner that cannot be read just then silences
    /// nothing: what the run found is still of the recorder it knew as it began.
    ///
    /// It runs in the caller's task, and stops between steps once that is cancelled, which is what the system
    /// does when the run's time is up: the request of its own that is under way is waited for, and nothing is
    /// asked after it -- not the free space after the slot, no guide, and not the logos of a type whose guide
    /// was the file that was out (`GuideRefresh.run`). The round of what waits is the one exception, and is
    /// finished row by row whatever the task says: it is run in the queue's own turn, which a caller's
    /// cancellation does not reach (`PendingQueue.flush`), and its rows are reservations the reader made.
    /// Of what the run has found by then only what became of what waited is told, and only when it is
    /// news (`tells`): what became of the reader's reservations stands whatever cut the run short. One held
    /// after silence at its create is such news, since it is held on the phone and waits for the reader.
    /// Silence at a read is not told as a stop: the suspension may be what cut the request, and the recorder is
    /// not to be said to have stopped answering on that account. Nothing else is told then -- no free space,
    /// whose notice writes down that it warned, and no guide fetched, which writes the time the settings show:
    /// the task has been completed by then, and what the system allows after that is not to be counted on.
    ///
    /// Once a telling is kept back, for the time or for the cache, the run ends and hands back that nothing
    /// was stored, whatever the guide had put in the cache: nothing reads the value by then, the task having
    /// been completed, and a cache made over holds none of it. `sendPacket` is `reachWithNoScreen`'s.
    ///
    /// With `nextRun`, when the next overnight run is asked for, the run tells once what the television's runs
    /// tell once, by their rule (`ToldOnce.after`) in the recorder's words (`NoScreenWords.recorder`), against
    /// what was `told` before, which the app keeps between runs. What the sending came to is settled for that
    /// rule first: nobody reached, or a recorder that could not be told apart, is the recorder not reached;
    /// another recorder with something waiting that would have gone is another recorder, and with nothing
    /// such it is nothing waiting, so that a stranger is told of only when something waits; a round is the
    /// round as it ran. Then:
    ///  - that the queue was held back is handed over only when it is news: the stop told last was not this
    ///    one, and the notice below does not carry it;
    ///  - what is told once is handed over as `NightFound.told`, at each way out of the sending -- nobody
    ///    reached, another recorder, the round told -- and so before the free space and the guide: a
    ///    reservation that starts before the next run and has not reached the recorder, in a notice of its
    ///    own with what stands in its way, and what to keep.
    /// Nothing of it is handed over once the time is up or the cache has become another recorder's, as above:
    /// nothing is then written, and the next run tells it. For these the cache is looked at once more, in
    /// another way: whose it is is noted as the run begins (`GuideStore.owner`), and nothing of them is handed
    /// over -- not that the queue was held back either -- once it is another's than the one noted
    /// (`madeOver`). The look above goes by what the client heard the recorder say it is, and a run that
    /// reached nobody heard nothing, as one answered by another recorder heard nothing of the cache's own:
    /// what such a run has to keep is made of what was told of the recorder before, and the app would write
    /// it over a cache the screens made over while the run was out, after they had forgotten it. The run ends
    /// there, as where any telling is kept back: also when the recorder that answers is the one the cache was
    /// made over to, whose round it has run by then and told. A cache that had no owner as the run began, and
    /// an owner that cannot be read then or as the run tells, keep nothing back. A night that another recorder
    /// answered looks at the time and at the owner noted twice: before it hands over that the queue was held
    /// back, and again before what is told once, the app posting its notification between the two, which can
    /// take a while. With no `nextRun` none of this is done but for that look: the queue held back is told
    /// whenever something waits and the cache is whose it was, and nothing else.
    public nonisolated static func refreshWithNoScreen(_ client: RecorderClient, store: GuideStore,
                                                       told: ToldOnce = ToldOnce(), nextRun: Date? = nil,
                                                       sendPacket: @escaping @Sendable () -> Bool,
                                                       found: @Sendable (NightFound) async -> Void) async -> Bool {
        // Whose cache it is as the run begins, for what is told once.
        let owner = try? await store.owner()
        guard await reachWithNoScreen(client, sendPacket: sendPacket) else {
            _ = await tellOnce(after: .unreachable, told, before: nextRun, of: client, in: store, since: owner,
                               to: found)
            return false
        }
        guard !Task.isCancelled else { return false }
        // Another recorder than the one this cache is of is left alone: see `isTheOneKnown`.
        // Said only when something was waiting to go to it, which is what the reader would otherwise miss, and
        // with a next run only when it is news. One that cannot be told apart is left alone too, and nothing is
        // said of another recorder: none is known to have answered. It is told of as one not reached.
        switch await isTheOneKnown(client, to: store) {
        case .yes:
            break
        case .another:
            let waits = PendingQueue.hasSomethingToSend((try? await store.pendingReservations()) ?? [])
            let once = await once(after: waits ? .anotherAnswered : .nothingWaiting, told, before: nextRun,
                                  in: store)
            // The cache is another's here by what answered, which keeps nothing back: the time does, and a
            // make-over while the run was out, which is told by the owner noted as it began.
            guard !Task.isCancelled, !(await madeOver(store, since: owner)) else { return false }
            if once.heldBackIsNews { await found(.heldBack) }
            // Both once more behind that telling, where the app posts its notification.
            if let kept = once.kept, !Task.isCancelled, !(await madeOver(store, since: owner)) {
                await found(.told(notYet: once.notYet, withdraws: once.withdrawsNotYet, kept: kept))
            }
            return false
        case .cannotBeTold:
            _ = await tellOnce(after: .unreachable, told, before: nextRun, of: client, in: store, since: owner,
                               to: found)
            return false
        }

        var outcome = await PendingQueue.flush(client: client, store: store)
        // What the sending came to, for what is told once: the round as it ran, before the time being up
        // takes its stop off below.
        let came = NoScreenSending.sent(outcome)
        // The cache made over to another recorder while the round was out: nothing is told from here on.
        guard await isTheOneKnown(client, to: store) != .another else { return false }
        // The time ran out while the round was out. What became of what waited is told when it is news, and
        // the run ends. A round that silence cut short at a read is told as one that was not cut short: the
        // queue's sentence for that says the rest goes the next time the recorder answers, as of a recorder that
        // went away. One cut short at a create keeps its stop, which is what says that the reservation is held.
        if Task.isCancelled {
            if outcome.stopped == .silent(afterSending: false) { outcome.stopped = nil }
            if tells(outcome, naming: nil) != nil { await found(.queue(outcome)) }
            return false
        }
        await found(.queue(outcome))
        // What is told once, ahead of whatever ends the run next: a round that met silence leaves rows that
        // may be due before the next run.
        guard await tellOnce(after: came, told, before: nextRun, of: client, in: store, since: owner,
                             to: found) else { return false }
        // A round that met silence has been told, and ends the run: the slot would wait the silence out next.
        // So does the night's time having run out, or the cache having become another recorder's, while that
        // was told: the two looks a telling makes, made here behind one.
        guard !outcome.interrupted, await mayStillTell(of: client, in: store) else { return false }
        // The slot first, so that the internal disk's notice can say which disk it is about once there are two.
        // Read through the one rule the screens use: only a disk the recorder registered counts. It lets only
        // silence out, and silence ends the run here: the free space and the guide would each wait it out again.
        // An answer of none, which a recorder just woken gives with a disk in the slot, lets no disk go: the disk
        // kept with the cache stays for the screens to settle. While that disk takes recordings there are still
        // two disks, so the internal disk's notice names its disk as the screens do, and the slot is read once
        // more after the guide, which gives the disk a while to come up, for the USB disk's notice. One request
        // more on such a night, and none in a home with no USB disk known.
        let usb: RecorderDisk?
        do {
            usb = try await usbDisk(of: client)
        } catch {
            return false
        }
        // The time ran out while the slot was read: nothing is asked after it.
        guard !Task.isCancelled else { return false }
        let second = usb?.takesRecordings == true ? usb : nil
        let known = usb == nil ? (try? await store.knownUSBDisk()) : nil
        let readAgain = known?.takesRecordings == true
        // The free space as the screens read it (`storage(of:)`): a recorder that will not say, or that says a
        // disk of no size, has not said, and nothing is told of it. Its silence ends the run -- after the USB
        // disk's space, which the slot answered before it.
        let space: (free: Int, total: Int)?
        let answered: Bool
        do {
            (space, answered) = (try await storage(of: client), true)
        } catch {
            (space, answered) = (nil, false)
        }
        if let space {
            let naming = second != nil || readAgain ? RecorderDisk.label(RecorderDisk.internalID, named: nil) : nil
            guard await tell(.freeSpace(free: space.free, total: space.total, naming: naming), of: client,
                             in: store, to: found) else { return false }
        }
        if let second {
            guard await tell(.usbSpace(second), of: client, in: store, to: found) else { return false }
        }
        // Before the guide, the two looks a telling makes, though nothing may have been told since the round:
        // no file is asked for by a night whose time is up, or for a cache that is another recorder's by now.
        guard answered, await mayStillTell(of: client, in: store) else { return false }

        // A broadcasting type that could not be fetched is passed over, and the screens fetch it at the next
        // connect: nothing marks it fetched. Handed the recorder that answered this run, as it described itself:
        // should the screens make the cache over to another meanwhile, it takes nothing more of this one's guide.
        // The two looks are made again once the guide's turn has come, behind a wait that can be as long as a
        // refresh of the screens' takes: turned away there the night has asked for no file, and ends as it
        // does where a telling is kept back.
        let answering = await client.info
        let refresh = await GuideRefresh.run(asked: .all, onTurn: {
            guard await mayStillTell(of: client, in: store) else { return .turnedAway(nil) }
            return .fetch(client: client, store: store, from: answering)
        })
        // Not told of a guide the cache ended by being made over, nor is anything handed back as stored then:
        // such a cache is another recorder's, which is where the telling ends the run.
        if !refresh.answered.isEmpty {
            guard await tell(.fetched(Date()), of: client, in: store, to: found) else { return false }
        }
        // Not after a guide that silence stopped: one request more of a recorder just found silent.
        // Nothing is kept of what this read finds either: what the slot holds is for the screens' attach to say.
        if refresh.stopped == nil, readAgain, !Task.isCancelled, let again = try? await usbDisk(of: client),
           again.takesRecordings {
            guard await tell(.usbSpace(again), of: client, in: store, to: found) else { return false }
        }
        return refresh.stored > 0
    }

    /// Whether a night may still tell what it finds: not once its time is up, and not once the cache has
    /// become another recorder's (`refreshWithNoScreen`). An owner that cannot be read says nothing against it.
    private nonisolated static func mayStillTell(of client: RecorderClient, in store: GuideStore) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await isTheOneKnown(client, to: store) != .another
    }

    /// Hands `value` to `found` for a night that may still tell it (`mayStillTell`). Whether it was handed
    /// over.
    private nonisolated static func tell(_ value: NightFound, of client: RecorderClient, in store: GuideStore,
                                         to found: @Sendable (NightFound) async -> Void) async -> Bool {
        guard await mayStillTell(of: client, in: store) else { return false }
        await found(value)
        return true
    }

    /// What is told once after a sending that came to `sending`, against what was `told` before, by the rule
    /// the television's runs have (`ToldOnce.after`) in the recorder's words, the queue read as it stands now.
    /// With no next run nothing of it is done: there is nothing to keep, no notice, and another recorder
    /// answering is news each time. The rule's own sentence for the queue is not handed on -- the app posts
    /// what became of the queue from the round itself (`tells`) -- but for whether it has one after another
    /// recorder answered, which is whether that is news.
    private nonisolated static func once(after sending: NoScreenSending, _ told: ToldOnce, before nextRun: Date?,
                                         in store: GuideStore, now: Date = Date()) async -> NoScreenTold {
        guard let nextRun else { return NoScreenTold(heldBackIsNews: sending == .anotherAnswered) }
        let waiting = try? await store.pendingReservations()
        let (notices, kept) = told.after(sending, waiting: waiting, before: nextRun, now: now, naming: nil,
                                         words: .recorder)
        return NoScreenTold(heldBackIsNews: sending == .anotherAnswered && notices.queue != nil,
                            notYet: notices.notYet, withdrawsNotYet: notices.withdrawsNotYet, kept: kept)
    }

    /// Hands what is told once after `sending` to `found`, for a night that may still tell it (`tell`) and
    /// whose cache is not another recorder's than `owner`, noted as the night began (`madeOver`). False once
    /// it was kept back, which ends the night; true also with no next run, when there is nothing of it to
    /// hand over.
    private nonisolated static func tellOnce(after sending: NoScreenSending, _ told: ToldOnce,
                                             before nextRun: Date?, of client: RecorderClient,
                                             in store: GuideStore, since owner: String?,
                                             to found: @Sendable (NightFound) async -> Void) async -> Bool {
        let once = await once(after: sending, told, before: nextRun, in: store)
        guard let kept = once.kept else { return true }
        guard !(await madeOver(store, since: owner)) else { return false }
        return await tell(.told(notYet: once.notYet, withdraws: once.withdrawsNotYet, kept: kept), of: client,
                          in: store, to: found)
    }

    /// Whether the cache has become another recorder's than `owner`, which is whose it was as a run with no
    /// screen began: the screens took one up meanwhile (`GuideStore.claim`). Not where either cannot be said:
    /// a cache that had no owner or could not be read then, or cannot be read now.
    private nonisolated static func madeOver(_ store: GuideStore, since owner: String?) async -> Bool {
        guard let owner, let now = try? await store.owner() else { return false }
        return now != owner
    }

    // MARK: - the Shortcuts action

    /// Sends what waits in the queue for the recorder, for the Shortcuts action, which an automation runs as the
    /// phone joins the home Wi-Fi: what it came to (`NoScreenSending`).
    ///
    /// The queue is read before anything goes on the network. The automation runs at every arrival home,
    /// and most of them have nothing to send: a recorder woken for nothing is half a minute of a box
    /// starting up in the living room for no reason. The screens may be sending the same queue at the same
    /// moment -- the app open as the Wi-Fi comes back -- which `PendingQueue.flush` takes one at a time.
    ///
    /// A recorder that answered and cannot be told from the one the queue was made for (`isTheOneKnown`) is
    /// sent nothing, and the sending comes to what it does when nobody was reached: of the answers there are,
    /// the one that does not say another recorder answered. `sendPacket` is `reachWithNoScreen`'s.
    public nonisolated static func sendWithNoScreen(_ client: RecorderClient, store: GuideStore, now: Date = Date(),
                                                    sendPacket: @escaping @Sendable () -> Bool) async
        -> NoScreenSending {
        await sendWithNoScreen(client, store: store, told: ToldOnce(), nextRun: nil, now: now,
                               sendPacket: sendPacket).sending
    }

    /// The same, with what the sending has to tell once beside what it came to: against what was `told`
    /// before and for the reservations that start before `nextRun`, as the overnight run tells it
    /// (`refreshWithNoScreen`) and by the same rule, what the sending came to being settled the same way.
    /// The notice, its withdrawal and what to keep are handed back only by a run that may still tell them: not
    /// one whose task is cancelled, and not one whose round ended over a cache that had become another
    /// recorder's meanwhile. That another recorder answered is told whatever the task says, as the sending
    /// itself is: with the notice kept back it is news unless it was the stop told last, the notice no
    /// longer carrying it. With no `nextRun` there is nothing to keep and no notice, and another recorder
    /// answering is news each time.
    ///
    /// Nothing of it is handed back, that another recorder answered included, once the cache is another
    /// recorder's than it was as the sending began (`madeOver`), whichever way the sending ended: the screens
    /// have taken a recorder up meanwhile and forgotten what was told of the one before, and what this
    /// sending has to tell is of that one. What the sending came to is handed back all the same.
    public nonisolated static func sendWithNoScreen(_ client: RecorderClient, store: GuideStore, told: ToldOnce,
                                                    nextRun: Date?, now: Date = Date(),
                                                    sendPacket: @escaping @Sendable () -> Bool) async
        -> (sending: NoScreenSending, told: NoScreenTold) {
        let owner = try? await store.owner()
        let sending = await sendOnce(client, store: store, now: now, sendPacket: sendPacket)
        let once = await once(after: sending, told, before: nextRun, in: store, now: now)
        guard !(await madeOver(store, since: owner)) else { return (sending, NoScreenTold()) }
        // Another recorder's answer is what makes the cache another's here, and is no reason to keep it back.
        let may = sending == .anotherAnswered ? !Task.isCancelled : await mayStillTell(of: client, in: store)
        guard !may else { return (sending, once) }
        return (sending, NoScreenTold(heldBackIsNews: sending == .anotherAnswered && told.stop != .another))
    }

    /// What the action's sending comes to: the queue read first, the recorder reached, and the round run for
    /// the recorder the queue was made for alone.
    private nonisolated static func sendOnce(_ client: RecorderClient, store: GuideStore, now: Date,
                                             sendPacket: @escaping @Sendable () -> Bool) async -> NoScreenSending {
        let waiting = (try? await store.pendingReservations()) ?? []
        guard PendingQueue.hasSomethingToSend(waiting, now: now) else { return .nothingWaiting }
        guard await reachWithNoScreen(client, sendPacket: sendPacket) else { return .unreachable }
        switch await isTheOneKnown(client, to: store) {
        case .yes:
            return .sent(await PendingQueue.flush(client: client, store: store, now: now))
        case .another:
            return .anotherAnswered
        case .cannotBeTold:
            return .unreachable
        }
    }

    /// What a sending came to, in words, for the Shortcuts action's answer when it is run by hand. Nil when
    /// there is nothing to say: nothing waiting, or a round with nothing in it that was not cut short. For a
    /// round, what it has to tell (`tells`), naming `device` where the home has a television beside the recorder
    /// and a sentence has to say which the reservations went to. A round with no news may still have something
    /// for whoever ran the action -- a reservation the recorder was too busy for, which goes again by itself --
    /// and that is said as the queue says it; one cut short by silence before the queue had anything to say,
    /// with nothing sent, is `cutShortWithNoScreen`.
    public nonisolated static func says(_ sending: NoScreenSending, naming device: String?) -> String? {
        switch sending {
        case .nothingWaiting:
            nil
        case .unreachable:
            notReachedWithNoScreen
        case .anotherAnswered:
            anotherAnsweredWithNoScreen
        case .sent(let outcome):
            tells(outcome, naming: device) ?? outcome.says(naming: device)
                ?? (outcome.interrupted ? cutShortWithNoScreen : nil)
        }
    }

    /// What a round with no screen has to tell, for the notification of what became of what waited and for the
    /// Shortcuts action's answer. Nil when it has no news: nothing was sent, found on the recorder already,
    /// dropped as over or refused, and no reservation is held now. One the recorder was too busy for waits as
    /// it did, and one refused before was told when it was refused.
    ///
    /// Otherwise the queue's sentences (`PendingQueue.Outcome.says`), naming `device` as they do. A round that
    /// stopped at silence at a reservation's create ends with `heldAfterSilence` where the queue ends a round
    /// cut short with its clause, that the rest goes the next time the recorder answers, and says it alone
    /// when nothing else happened. Of that reservation the clause is not true: it may have been made, the
    /// round has held it for the reader (`PendingQueue.flush`), and nothing sends it again but the reader. A
    /// television's goes by itself, which is why the queue's own sentences cannot say this. The sentence is the
    /// one written on the row, read here as it stands.
    ///
    /// A round with news that passed over a reservation held after silence at an earlier create -- one whose
    /// reason, as the row carries it, is that sentence (`heldAfterSilence(matches:)`) -- ends by saying how many
    /// such there are (`stillHeldAfterSilence`). They are counted over the whole of what the round read: one
    /// that stopped counts the rows behind its stop as passed over too (`PendingQueue.flush`), so that a round
    /// cut short at a read says it of a reservation it never came to, where the queue's clause for a round cut
    /// short -- that the rest goes the next time -- is not true of it. What is told of a round takes the place
    /// of what was told of the round before: the notification is one, and a later round's would otherwise
    /// stand where the one that said the reservation is held stood, reading as if all had gone, of a row that
    /// is passed over with its reason and is no news. Not said by a round that itself stopped at silence at a
    /// create: that one says that a reservation is held and where to look, there the reader finds each, and
    /// one sentence about reservations held is enough. Not said with no news, where nothing is told and what
    /// was told before stands. A row the round took out as found on the recorder is held no longer, and is not
    /// counted.
    public nonisolated static func tells(_ outcome: PendingQueue.Outcome, naming device: String?) -> String? {
        let held = outcome.stopped == .silent(afterSending: true)
        guard held || !outcome.isEmpty else { return nil }
        var round = outcome
        // With no stop to it the queue says no clause for a round cut short.
        if held { round.stopped = nil }
        let before = held ? 0 : outcome.held.filter { $0.problem.map(heldAfterSilence(matches:)) == true }.count
        return [round.says(naming: device), held ? heldAfterSilence : nil,
                before > 0 ? stillHeldAfterSilence(before) : nil].compactMap { $0 }.joined(separator: "。")
    }

    /// Said last by a round with no screen that has news, of the reservations it passed over that are held
    /// after silence at an earlier create (`tells`): how many, and where to look. A line of the queue's kind,
    /// with no full stop of its own. It names the recorder whether or not the round's sentences name a
    /// device: only a recorder's reservation is held so.
    private nonisolated static func stillHeldAfterSilence(_ count: Int) -> String {
        "レコーダーに届いたか確かめていない予約が \(count) 件あります。予約一覧で確かめてください"
    }

    /// Said when another recorder than the one the queue was made for answered a run with no screen, in the
    /// notification and by the Shortcuts action when it is run by hand. The state the reader will find, in the
    /// words used when the recorder could not be reached. Not said of a recorder that merely could not be told
    /// from that one (`TheOneKnown.cannotBeTold`).
    public nonisolated static let anotherAnsweredWithNoScreen = "これまでとは別のレコーダーが応答したため、送信待ちの予約はそのまま残しています。"
        + "アプリを開いて確かめてください。"
    /// Said by the Shortcuts action when the recorder was not reached, and when one answered that could not be
    /// told from the recorder the queue was made for: the nearer of the two sentences there are, though it is
    /// not the cause when it is the phone's cache that could not be read.
    public nonisolated static let notReachedWithNoScreen = "レコーダーに接続できませんでした。送信待ちの予約はそのまま残しています。"
    /// Said by the Shortcuts action when its round was cut short by silence with nothing sent -- at the read
    /// that opens it -- and the queue has nothing to say of it. Silence at a reservation's create is said as the
    /// reservation being held (`tells`).
    public nonisolated static let cutShortWithNoScreen = "途中でレコーダーの応答がなくなりました。送信待ちの予約はそのまま残しています。"

    /// What stands in the way of the reservations that have not reached the recorder in time, after a run
    /// with no screen that came to `sending`; nil when nothing known does, and opening the app sends them.
    /// Another recorder, in the sentence said of it with no screen. The recorder not answering, when nobody
    /// was reached and when a round stopped at silence: at a create too, whose own row is held with a reason
    /// by then and is no late row, so that this is said of the rows behind it.
    nonisolated static func inTheWay(after sending: NoScreenSending) -> String? {
        switch sending {
        case .anotherAnswered:
            anotherAnsweredWithNoScreen
        case .unreachable:
            notAnsweringWithNoScreen
        case .sent(let outcome):
            outcome.interrupted ? notAnsweringWithNoScreen : nil
        case .nothingWaiting:
            nil
        }
    }

    /// The first sentence of the notice of reservations that have not reached the recorder in time: the first
    /// of `rows` by its title and its start in Japan, and how many more, as the television's names them
    /// (`TVDriver.notYetAtTheTelevision`).
    nonisolated static func notYetAtTheRecorder(_ rows: [PendingReservation]) -> String {
        rows.isEmpty ? "" : "レコーダーにまだ届いていない予約があります（\(ToldOnce.named(rows))）"
    }

    /// Said in that notice when the recorder did not answer a run with no screen: what waits goes by itself
    /// the next time it does.
    nonisolated static let notAnsweringWithNoScreen = "レコーダーが応答しないため送っていません。次にレコーダーが答えたときに送ります"
}
