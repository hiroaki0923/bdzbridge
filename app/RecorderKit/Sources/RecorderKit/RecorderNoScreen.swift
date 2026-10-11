import Foundation

/// What a night with no screen found, handed over as it finds it (`RecorderDriver.refreshWithNoScreen`) for the
/// app to tell: in notifications, and in the time the settings show.
public enum NightFound: Sendable {
    /// What waits was not sent, because the recorder that answered is not the one it was made for.
    case heldBack
    /// What became of what waited.
    case queue(PendingQueue.Outcome)
    /// The internal disk's free space and size, in bytes, with its label while a USB disk beside it takes
    /// recordings.
    case freeSpace(free: Int, total: Int, naming: String?)
    /// The USB disk, when it takes recordings.
    case usbSpace(RecorderDisk)
    /// A guide was fetched, at this time.
    case fetched(Date)
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
    /// the recorder known and the guide would go into a cache that is still its own. Nor when it cannot be told:
    /// an owner that cannot be read, a device that did not describe itself.
    public nonisolated static func isTheOneKnown(_ client: RecorderClient, to store: GuideStore) async -> Bool {
        guard let answering = await client.info, let who = try? await store.recognises(answering) else {
            return false
        }
        return who != .another
    }

    // MARK: - the overnight run

    /// The overnight run, with no screen behind it: the recorder is reached, woken if need be
    /// (`reachWithNoScreen`), what waits in the queue goes out while it is up, how much room is left is found
    /// out, and the guide is fetched, every type of it. Whether a programme was stored. What it finds on the way
    /// is handed to `found` as it finds it, each waited for before the next step: what became of the queue and
    /// the free space are told before a guide download that can outlast the task.
    ///
    /// Silence ends the run where it is first met: whatever came next would wait the same silence out again, of
    /// a recorder that has gone. A round of what waits that met it is told, and nothing is asked after it. The
    /// slot's ends it with nothing told. The free space's ends it once the USB disk's space has been told, where
    /// the slot had answered a disk that takes recordings: that was heard before the silence, and telling it
    /// asks nothing. In the guide, that a guide was fetched is told when a type answered before the silence, what
    /// was stored before it is handed back, and nothing more is asked. A night whose one silence passed gives up
    /// what it had not come to -- the free space, the guide -- until the next connect or the next night.
    ///
    /// A cache that is another recorder's by the time a file of the guide has come ends the run as well
    /// (`GuideRefresh.Stop.letGo`): it takes nothing of the file.
    ///
    /// It runs in the caller's task, and stops between steps once that is cancelled, which is what the system
    /// does when the run's time is up: the request under way is waited for, and nothing is asked after it.
    /// `sendPacket` is `reachWithNoScreen`'s.
    public nonisolated static func refreshWithNoScreen(_ client: RecorderClient, store: GuideStore,
                                                       sendPacket: @escaping @Sendable () -> Bool,
                                                       found: @Sendable (NightFound) async -> Void) async -> Bool {
        guard await reachWithNoScreen(client, sendPacket: sendPacket), !Task.isCancelled else { return false }
        // Another recorder than the one this cache is of is left alone: see `isTheOneKnown`.
        // Said only when something was waiting to go to it, which is what the reader would otherwise miss.
        guard await isTheOneKnown(client, to: store) else {
            if PendingQueue.hasSomethingToSend((try? await store.pendingReservations()) ?? []) {
                await found(.heldBack)
            }
            return false
        }

        let outcome = await PendingQueue.flush(client: client, store: store)
        await found(.queue(outcome))
        // A round that met silence has been told, and ends the run: the slot would wait the silence out next.
        guard !outcome.interrupted, !Task.isCancelled else { return false }
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
            await found(.freeSpace(free: space.free, total: space.total, naming: naming))
        }
        if let second { await found(.usbSpace(second)) }
        guard answered else { return false }

        // A broadcasting type that could not be fetched is passed over, and the screens fetch it at the next
        // connect: nothing marks it fetched. Handed the recorder that answered this run, as it described itself:
        // should the screens make the cache over to another meanwhile, it takes nothing more of this one's guide.
        let refresh = await GuideRefresh.run(client: client, store: store, from: await client.info)
        if !refresh.answered.isEmpty { await found(.fetched(Date())) }
        // Not after a guide that silence stopped: one request more of a recorder just found silent.
        // Nothing is kept of what this read finds either: what the slot holds is for the screens' attach to say.
        if refresh.stopped == nil, readAgain, !Task.isCancelled, let again = try? await usbDisk(of: client),
           again.takesRecordings {
            await found(.usbSpace(again))
        }
        return refresh.stored > 0
    }

    // MARK: - the Shortcuts action

    /// Sends what waits in the queue for the recorder, for the Shortcuts action, which an automation runs as the
    /// phone joins the home Wi-Fi: what it came to (`NoScreenSending`).
    ///
    /// The queue is read before anything goes on the network. The automation runs at every arrival home,
    /// and most of them have nothing to send: a recorder woken for nothing is half a minute of a box
    /// starting up in the living room for no reason. The screens may be sending the same queue at the same
    /// moment -- the app open as the Wi-Fi comes back -- which `PendingQueue.flush` takes one at a time.
    /// `sendPacket` is `reachWithNoScreen`'s.
    public nonisolated static func sendWithNoScreen(_ client: RecorderClient, store: GuideStore, now: Date = Date(),
                                                    sendPacket: @escaping @Sendable () -> Bool) async
        -> NoScreenSending {
        let waiting = (try? await store.pendingReservations()) ?? []
        guard PendingQueue.hasSomethingToSend(waiting, now: now) else { return .nothingWaiting }
        guard await reachWithNoScreen(client, sendPacket: sendPacket) else { return .unreachable }
        guard await isTheOneKnown(client, to: store) else { return .anotherAnswered }
        return .sent(await PendingQueue.flush(client: client, store: store, now: now))
    }

    /// What a sending came to, in words, for the Shortcuts action's answer when it is run by hand. Nil when
    /// there is nothing to say: nothing waiting, or a round with nothing in it that was not cut short. For a
    /// round, what the queue says of it, naming `device` where the home has a television beside the recorder and
    /// a sentence has to say which the reservations went to; a round cut short by silence before the queue had
    /// anything to say is `cutShortWithNoScreen`.
    public nonisolated static func says(_ sending: NoScreenSending, naming device: String?) -> String? {
        switch sending {
        case .nothingWaiting:
            nil
        case .unreachable:
            notReachedWithNoScreen
        case .anotherAnswered:
            anotherAnsweredWithNoScreen
        case .sent(let outcome):
            outcome.says(naming: device) ?? (outcome.interrupted ? cutShortWithNoScreen : nil)
        }
    }

    /// Said when another recorder than the one the queue was made for answered a run with no screen, in the
    /// notification and by the Shortcuts action when it is run by hand. The state the reader will find, in the
    /// words used when the recorder could not be reached.
    public nonisolated static let anotherAnsweredWithNoScreen = "これまでとは別のレコーダーが応答したため、送信待ちの予約はそのまま残しています。"
        + "アプリを開いて確かめてください。"
    /// Said by the Shortcuts action when the recorder was not reached.
    public nonisolated static let notReachedWithNoScreen = "レコーダーに接続できませんでした。送信待ちの予約はそのまま残しています。"
    /// Said by the Shortcuts action when its round was cut short by silence and the queue has nothing to say
    /// of it.
    public nonisolated static let cutShortWithNoScreen = "途中でレコーダーの応答がなくなりました。送信待ちの予約はそのまま残しています。"
}
