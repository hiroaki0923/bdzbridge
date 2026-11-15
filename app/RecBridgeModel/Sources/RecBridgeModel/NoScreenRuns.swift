import Foundation
import RecorderKit

/// What the app does with no screen behind it -- the overnight run and the Shortcuts action's sending -- with
/// what it reaches of its platform handed in (`NoScreenSurroundings`), and what the action says it came to. What
/// the system calls -- the overnight task, registered and scheduled, and the Shortcuts action -- is the app's,
/// which hands in its own (`BackgroundWork.swift`).
public enum BackgroundWork {
    /// The next 02:00 in the recorder's own time zone (`GuideRefresh.nextNightlyRun`). The box rebuilds its guide
    /// files around 00:49.
    public static func nextNightlyRun(after now: Date = Date()) -> Date {
        GuideRefresh.nextNightlyRun(after: now)
    }

    /// Whether a television is saved beside the recorder, for what runs with no screen and so has no model to
    /// ask: read from what the screens saved, as the recorder's address is. With one saved, what became of the
    /// recorder's queue says which device it went to (`Notify.queueFlushed`, `BackgroundWork.saying`), and
    /// the television's part tells nothing of a television taken away while it was out.
    public static func televisionSaved(in defaults: UserDefaults) -> Bool {
        !(defaults.string(forKey: DefaultsKey.tvHost) ?? "").isEmpty
    }

    // MARK: - the entries

    /// The work of the overnight run, with no screen behind it -- the television's part beside the recorder's.
    /// The television's runs whether or not a recorder is saved, so a home with a television alone has one too.
    /// Both are awaited before the task is completed, unless its time runs out first: the app's handler then
    /// completes it, and each part sees the cancellation only where it looks for it. An `async let` left
    /// unawaited is cancelled as the scope ends, so each is awaited on the one way out.
    @discardableResult
    public static func refreshNow(in surroundings: NoScreenSurroundings) async -> Bool {
        async let television = sendToTheTelevisionNow(in: surroundings)
        let refreshed = await refreshTheRecorderNow(in: surroundings)
        _ = await television
        return refreshed
    }

    /// The recorder's part: the address comes from what the screens saved, and the cache is opened directly. The
    /// recorder is asleep most of the time -- measured over twelve hours, it was answering for a quarter of it --
    /// so this wakes it rather than give up. Whatever is waiting in the queue goes out while the recorder is up,
    /// and the reader is told. Nothing is opened, asked, posted or written in the demo, with no recorder saved,
    /// and with no cache.
    ///
    /// What the runs with no screen told of the recorder before is handed in to be read
    /// (`DefaultsKey.recorderTold`, `KeptOnce`) with the hour of the next run, so that another recorder
    /// answering, and a reservation that will start before that run and has not reached the recorder, are told
    /// once (`RecorderDriver.refreshWithNoScreen`). What has been told from then on is written back as the run
    /// hands it over (`Telling.through`), whether or not a notification could be heard, as the television's is
    /// (`sendToTheTelevisionNow`).
    ///
    /// Stops between steps once its time is up: the task has been completed by then, and what the system allows
    /// after that is not to be counted on. Nothing is told or written from then on but what became of the
    /// waiting reservations, when that is news.
    private static func refreshTheRecorderNow(in surroundings: NoScreenSurroundings) async -> Bool {
        let defaults = surroundings.defaults
        // Nothing to fetch and nobody to wake while the demo is on the screen.
        guard !DemoData.on(in: defaults) else { return false }
        guard let host = defaults.string(forKey: DefaultsKey.recorderHost), !host.isEmpty,
              let store = surroundings.openGuide() else {
            return false
        }
        return await refresh(client: RecorderClient(host: host, transport: surroundings.transport(host)), store: store,
                             mac: defaults.string(forKey: DefaultsKey.recorderMac), telling: .through(surroundings),
                             told: KeptOnce.recorder(in: defaults).reading, nextRun: nextNightlyRun())
    }

    /// The television's part of a run with no screen, from what the screens saved: its address and MAC in the
    /// defaults, its registration where the platform keeps it, the cache opened directly, a transport that keeps
    /// no cookies. What it found is posted (`Notifications.television`), what was told is written back
    /// (`KeptOnce`), as the run hands them over, and what it came to is handed back for the Shortcuts action to
    /// say. Nil, with nothing opened, asked, posted or written, in the demo, with no television saved, and with
    /// no cache.
    ///
    /// Nothing is posted or written when the television was taken away while the run was out. Once the task's
    /// time is up, only what the queue says of its rows is posted, without its sentence for a round cut short
    /// by silence, and nothing is written. That is inferred, not seen: a request the suspension cut would come
    /// back, once the process resumes, as a failure of the transport, which the client reads as silence.
    /// Apple's page on `BGProcessingTask` says that "the system can interrupt the process". Its archived
    /// TN2277, "Networking and Multitasking", is about BSD sockets and what was built on them before
    /// `URLSession`: once an app is suspended, "the socket's resources might get reclaimed by the kernel, after
    /// which all networking operations on the socket will fail". What becomes of a `URLSession` request then
    /// is in no page read. Silence so read is not the television's doing.
    ///
    /// What was told is written whether or not a notification could be heard: one posted with the quiet
    /// permission the app takes at its first connect still reaches Notification Centre, and a reader who
    /// said no would hear nothing either way.
    @discardableResult
    public static func sendToTheTelevisionNow(in surroundings: NoScreenSurroundings) async -> NoScreenSending? {
        let defaults = surroundings.defaults
        guard !DemoData.on(in: defaults), let host = defaults.string(forKey: DefaultsKey.tvHost), !host.isEmpty,
              let store = surroundings.openGuide() else {
            return nil
        }
        let client = ScalarClient(host: host, transport: surroundings.tvTransport(host),
                                  credentials: surroundings.tvCredentials)
        let kept = KeptOnce.television(in: defaults)
        let now = Date()
        let run = await sendToTheTelevision(client: client, store: store,
                                            mac: defaults.string(forKey: DefaultsKey.tvMac), told: kept.reading,
                                            nextRun: nextNightlyRun(after: now), now: now) { sending, notices, told in
            // Taken away while the run was out: what it found is no longer anybody's to be told.
            guard televisionSaved(in: surroundings.defaults) else { return }
            // The task's time ran out while the run was out.
            if Task.isCancelled {
                if case .sent(var outcome) = sending, !outcome.isEmpty {
                    // The suspension may be what cut the round short, and the television is not to be said to.
                    if outcome.interrupted { outcome.stopped = nil }
                    await surroundings.notifications.television(
                        NoScreenNotices(queue: outcome.says(naming: DeviceSlot.tv.label)))
                }
                return
            }
            await surroundings.notifications.television(notices)
            kept.keep(told)
        }
        return run.sending
    }

    /// Sends what is waiting in the queue, for the Shortcuts action (`SendWaitingIntent` in the app), which an
    /// automation runs as the phone joins the home Wi-Fi. The reader hears the outcome the way the overnight run
    /// tells it: what became of a round, when it has news (`Notifications.queueFlushed`); that another recorder
    /// answered, when that is news; and the warning of reservations that have not reached the recorder in time,
    /// posted or taken away (`Notifications.recorder`). `.demo` and `.noRecorder`, with nothing opened, asked,
    /// posted or written, in the demo, and with no recorder saved or no cache.
    ///
    /// What was told before is handed in to be read (`DefaultsKey.recorderTold`, `KeptOnce`) with the hour of the
    /// next overnight run, and what the sending hands over to keep is written under the same key, whether or not
    /// a notification could be heard. Whether each is told, and whether anything is kept, is the driver's
    /// (`RecorderDriver.sendWithNoScreen`): nothing is written for a sending whose task was cancelled, or whose
    /// cache became another recorder's while it was out.
    public static func sendWaiting(in surroundings: NoScreenSurroundings) async -> Sending {
        let defaults = surroundings.defaults
        guard !DemoData.on(in: defaults) else { return .demo }
        guard let host = defaults.string(forKey: DefaultsKey.recorderHost), !host.isEmpty,
              let store = surroundings.openGuide() else {
            return .noRecorder
        }
        let kept = KeptOnce.recorder(in: defaults)
        let notifications = surroundings.notifications
        let client = RecorderClient(host: host, transport: surroundings.transport(host))
        let (sending, _) = await sendWaiting(client: client, store: store,
                                             mac: defaults.string(forKey: DefaultsKey.recorderMac),
                                             told: kept.reading, nextRun: nextNightlyRun()) { sending, news in
            if case .sent(let outcome) = sending { await notifications.queueFlushed(outcome) }
            if news.heldBackIsNews { await notifications.queueHeldBack() }
            await notifications.recorder(news.notYet, news.withdrawsNotYet)
            if let told = news.kept { kept.keep(told) }
        }
        return sending
    }

    // MARK: - with the client and the cache handed in

    /// The television's part with its client and cache handed in, which is what most of the tests give it: the
    /// run, the queue read after it, and what that tells against what was told before (`ToldOnce.after`), which
    /// `told` reads, with
    /// the television named as the screens name it. What it tells and what is told from then on are handed to
    /// `tell`, which is where the entry posts and keeps them, and handed back. All of that is done inside the
    /// queue's turn, the round's or one of its own (`TVDriver.sendWithNoScreen(_:store:knownAs:now:then:)`):
    /// what the screens send or forget in the turn comes wholly before it or wholly after it; a registration
    /// also forgets at once, outside the turn, which can fall inside a telling, and once more in the turn,
    /// which then comes after that telling and takes away only what is kept under a registration before it:
    /// what is kept carries the registration it was learnt under (`ToldOnce.registration`).
    public static func sendToTheTelevision(client: ScalarClient, store: GuideStore, mac: String?,
                                           told reading: @escaping @Sendable () -> ToldOnce, nextRun: Date,
                                           now: Date = Date(),
                                           tell: @escaping @Sendable (NoScreenSending, NoScreenNotices, ToldOnce) async
                                               -> Void)
        async -> (sending: NoScreenSending, notices: NoScreenNotices, told: ToldOnce) {
        let (sending, told) = await TVDriver.sendWithNoScreen(client, store: store, knownAs: mac,
                                                              now: now) { sending, registration, refusedBefore in
            let waiting = try? await store.pendingReservations()
            let (notices, after) = reading().after(sending, waiting: waiting, before: nextRun, now: now,
                                                   naming: DeviceSlot.tv.label, registration: registration,
                                                   refusedForTheCookieBefore: refusedBefore)
            await tell(sending, notices, after)
            return (notices: notices, after: after)
        }
        return (sending, told.notices, told.after)
    }

    /// How a run with no screen tells the reader what it did, and what it keeps for the screens to show.
    /// Handed in, so that the run can be tried without the notifications and the settings of whatever it is
    /// tried on (`refresh`).
    public struct Telling: Sendable {
        /// The queue was not sent, because the recorder that answered is not the one it was made for. Asked
        /// only when the run has that to tell (`NightFound.heldBack`): with a next run handed in, not when it
        /// was the stop told last.
        var heldBack: @Sendable () async -> Void
        /// What became of the queue, from a night whose cache is still its recorder's: of every round while it
        /// still has its time, and only of a round with news once that is up. Whether there is anything to say
        /// of it is asked again where it is posted (`Notify.queueFlushed`).
        var flushed: @Sendable (PendingQueue.Outcome) async -> Void
        /// The internal disk's free space, with its label while a USB disk beside it takes recordings.
        var freeSpace: @Sendable (_ freeBytes: Int, _ totalBytes: Int, _ naming: String?) async -> Void
        /// The USB disk's, when it takes recordings.
        var usbSpace: @Sendable (RecorderDisk) async -> Void
        /// What is told once (`NightFound.told`): the notice of reservations that have not reached the recorder
        /// in time, whether the last such notice is taken away, and what has been told, to keep for the next
        /// run. Nothing, unless said: a run handed no next run tells none of it.
        var kept: @Sendable (_ notYet: String?, _ withdraws: Bool, _ told: ToldOnce) async -> Void
        /// A guide was fetched, at this time.
        var fetched: @Sendable (Date) -> Void

        public init(heldBack: @escaping @Sendable () async -> Void,
                    flushed: @escaping @Sendable (PendingQueue.Outcome) async -> Void,
                    freeSpace: @escaping @Sendable (_ freeBytes: Int, _ totalBytes: Int, _ naming: String?) async -> Void,
                    usbSpace: @escaping @Sendable (RecorderDisk) async -> Void,
                    kept: @escaping @Sendable (_ notYet: String?, _ withdraws: Bool, _ told: ToldOnce) async -> Void
                        = { _, _, _ in },
                    fetched: @escaping @Sendable (Date) -> Void) {
            self.heldBack = heldBack
            self.flushed = flushed
            self.freeSpace = freeSpace
            self.usbSpace = usbSpace
            self.kept = kept
            self.fetched = fetched
        }
    }

    /// The recorder's part of the overnight run with its client and cache handed in, which is what most of the
    /// tests give it. They hand it no MAC, for the reason they hand `sendWaiting` none.
    ///
    /// The run and its order are the driver's (`RecorderDriver.refreshWithNoScreen`): the packet is handed to
    /// it, and each thing it hands over is told here as it comes. What to tell, and what to keep back -- once
    /// the task's time is up, once the cache is another recorder's -- is the driver's as well. `told` and
    /// `nextRun` are handed on to it for what is told once; with no next run, as a test that does not look at
    /// that hands none, nothing of it is done and nothing comes to `Telling.kept`.
    public static func refresh(client: RecorderClient, store: GuideStore, mac: String?, telling: Telling,
                               told: @escaping @Sendable () -> ToldOnce = { ToldOnce() }, nextRun: Date? = nil) async -> Bool {
        await RecorderDriver.refreshWithNoScreen(client, store: store, told: told, nextRun: nextRun,
                                                 sendPacket: packet(for: client, mac: mac)) { found in
            switch found {
            case .heldBack: await telling.heldBack()
            case .queue(let outcome): await telling.flushed(outcome)
            case .told(let notYet, let withdraws, let kept): await telling.kept(notYet, withdraws, kept)
            case .freeSpace(let free, let total, let naming): await telling.freeSpace(free, total, naming)
            case .usbSpace(let disk): await telling.usbSpace(disk)
            case .fetched(let at): telling.fetched(at)
            }
        }
    }

    /// What sending the queue with nothing on screen came to, for the Shortcuts action to say.
    public enum Sending: Equatable, Sendable {
        case demo
        case noRecorder
        /// Nothing the recorder could be sent: the queue is empty, or holds only what it refused before, or
        /// what has finished. The recorder was not asked.
        case nothingWaiting
        /// Nobody answered at the address, or a recorder did that could not be told from the one the queue and
        /// the cache are of (`TheOneKnown.cannotBeTold`). Nothing was sent.
        case unreachable
        /// A recorder answered, and not the one the queue and the cache are of. Nothing was sent to it.
        case anotherRecorder
        case sent(PendingQueue.Outcome)
    }

    /// The Shortcuts action's sending with its client and cache handed in, which is what most of the tests give
    /// it. They hand it no MAC: the packet goes out from here (`packet`) and not through `Surroundings`, so one
    /// handed in is sent on whatever network the tests are run on.
    ///
    /// The sending and its order are the driver's (`RecorderDriver.sendWithNoScreen`), which reads the queue
    /// before anything goes on the network; what it came to is said here as the action's own `Sending`.
    static func sendWaiting(client: RecorderClient, store: GuideStore, mac: String?,
                            now: Date = Date()) async -> Sending {
        await sendWaiting(client: client, store: store, mac: mac, told: { ToldOnce() }, nextRun: nil, now: now,
                          tell: { _, _ in }).sending
    }

    /// The same, handing back with the sending what it has to tell once (`NoScreenTold`), against what was told
    /// before, which `told` reads, and for the reservations that start before `nextRun`: whether another
    /// recorder answering is news, the notice of reservations that have not reached the recorder in time and
    /// its withdrawal, and what to keep. The two are handed to `tell` inside the queue's turn, which is where the
    /// entry posts and keeps them; whether there is anything to tell is the driver's
    /// (`RecorderDriver.sendWithNoScreen`).
    public static func sendWaiting(client: RecorderClient, store: GuideStore, mac: String?,
                                   told: @escaping @Sendable () -> ToldOnce, nextRun: Date?, now: Date = Date(),
                                   tell: @escaping @Sendable (NoScreenSending, NoScreenTold) async -> Void) async
        -> (sending: Sending, news: NoScreenTold) {
        let (came, news) = await RecorderDriver.sendWithNoScreen(client, store: store, told: told, nextRun: nextRun,
                                                                 now: now, sendPacket: packet(for: client, mac: mac),
                                                                 tell: tell)
        let sending: Sending = switch came {
        case .nothingWaiting: .nothingWaiting
        case .unreachable: .unreachable
        case .anotherAnswered: .anotherRecorder
        case .sent(let outcome): .sent(outcome)
        }
        return (sending, news)
    }

    /// The magic packet for the recorder the client asks, to the MAC the app wrote down the last time it
    /// reached it, and whether one went out: without a MAC there is nothing to send and nothing to wait for.
    /// It goes before the first probe (`RecorderDriver.reachWithNoScreen`), which saves five seconds the
    /// Shortcuts action can ill afford: how long the system lets it run in the background is not published.
    private static func packet(for client: RecorderClient, mac: String?) -> @Sendable () -> Bool {
        let host = client.host
        return { mac.map { WakeOnLan.wake($0, addresses: WakeOnLan.addresses(forRecorderAt: host)) > 0 } ?? false }
    }

    /// What the action says with the television's sending beside the recorder's. With none -- no television
    /// saved, or the demo -- it is `saying(_:televisionSaved:)`, as it has always been. With one: the
    /// recorder's sentence as that gives it with a television saved, then the television's
    /// (`TVDriver.says`); a device with nothing to say is left out, and with neither, 「送信待ちの予約はありません。」
    /// once. The television has nothing to say only when nothing waited for it, or another sending took what
    /// did. The recorder has nothing to say in a home with no recorder, with nothing waiting for it, and after a
    /// sending with nothing in it that was not cut short. Two sentences are joined with 。, each without its own
    /// at the end; the answer ends with one, as a body does (`String.asABody`).
    public static func saying(_ sending: BackgroundWork.Sending, beside television: NoScreenSending?,
                              televisionSaved: Bool) -> String {
        guard let television else { return saying(sending, televisionSaved: televisionSaved) }
        var recorders: String?
        switch sending {
        case .noRecorder, .nothingWaiting:
            break
        case .sent(let outcome) where outcome.said(withATelevisionSaved: true) == nil && !outcome.interrupted:
            break
        default:
            recorders = saying(sending, televisionSaved: true)
        }
        let halves = [recorders, TVDriver.says(television, naming: DeviceSlot.tv.label)].compactMap { $0 }
        guard halves.count > 1 else { return halves.first?.asABody ?? "送信待ちの予約はありません。" }
        return halves.map { $0.hasSuffix("。") ? String($0.dropLast()) : $0 }.joined(separator: "。").asABody
    }

    /// What the action says when it is run by hand. An automation that runs by itself shows nothing of it,
    /// which is why what was sent is also a notification, as it is from the overnight run.
    ///
    /// `televisionSaved`: the reader has a television beside the recorder, and what became of the queue then
    /// says which device it went to: the recorder's word is handed to the driver's sentences, as the strip's
    /// are named (`PendingQueue.Outcome.said(withATelevisionSaved:)`). Handed in, since nothing here has a model
    /// to ask; left out, it is a home with a recorder alone, whose sentences are as they have always been.
    ///
    /// What the recorder's sending came to is said in the driver's sentences (`RecorderDriver.says`), ended with
    /// 。 as a body is (`String.asABody`), and 「送信待ちの予約はありません。」 where those have nothing to say;
    /// the demo and a home with no recorder are the app's to say. Of a round the driver says what the
    /// notification says of it (`RecorderDriver.tells`), a reservation held after silence at its create among
    /// it, and beyond that what a round with no news still has for whoever ran the action. `.unreachable` is also a recorder that
    /// answered and could not be told from the one the queue was made for, said as one not reached. Nothing
    /// is read, kept or written here: what is told once is the entry's (`BackgroundWork.sendWaiting(in:)`), and
    /// is a notification, not part of the answer.
    static func saying(_ sending: BackgroundWork.Sending, televisionSaved: Bool = false) -> String {
        let recorders: NoScreenSending
        var device: String?
        switch sending {
        case .demo:
            return "サンプルデータの表示中は送りません。"
        case .noRecorder:
            return "レコーダーが設定されていません。"
        case .nothingWaiting:
            recorders = .nothingWaiting
        case .unreachable:
            recorders = .unreachable
        case .anotherRecorder:
            recorders = .anotherAnswered
        case .sent(let outcome):
            recorders = .sent(outcome)
            if televisionSaved { device = outcome.slot.label }
        }
        return RecorderDriver.says(recorders, naming: device)?.asABody ?? "送信待ちの予約はありません。"
    }
}

extension BackgroundWork.Telling {
    /// What a night tells through the notifications handed in, and what it keeps where the screens read it: what
    /// has been told once (`KeptOnce`), once its notice has been posted, and the time the settings show
    /// (`AppModel.lastOvernightRefresh`).
    static func through(_ surroundings: NoScreenSurroundings) -> Self {
        let notifications = surroundings.notifications
        return Self(heldBack: notifications.queueHeldBack,
                    flushed: notifications.queueFlushed,
                    freeSpace: notifications.lowSpace,
                    usbSpace: notifications.usbLowSpace,
                    kept: { notYet, withdraws, told in
                        await notifications.recorder(notYet, withdraws)
                        KeptOnce.recorder(in: surroundings.defaults).keep(told)
                    },
                    fetched: {
                        surroundings.defaults.set(RecorderTime.format($0), forKey: DefaultsKey.lastBackgroundRefresh)
                    })
    }
}

/// What a run with no screen reaches of the platform it runs on, having no model to ask: what the screens saved,
/// the guide's folder, the way to each device, where the television's registration is kept, and the
/// notifications. The app hands in its own (`NoScreenSurroundings.app`), and a test its own.
///
/// Handed to both parts of a run, each in a task of its own, and Sendable by hand for that: `UserDefaults` is not
/// marked so, and Apple's page for it says that it "is thread-safe, and you can use the same object in multiple
/// threads or tasks simultaneously". Everything else here is Sendable.
public struct NoScreenSurroundings: @unchecked Sendable {
    /// What the screens saved -- the addresses, the MACs, whether the demo is on -- and where a run keeps what it
    /// has told once and when it last fetched a guide: the defaults the model is given (`Surroundings.defaults`).
    let defaults: UserDefaults
    /// The folder the guide's database is in, the model's (`Surroundings.folder`): asked only once a run has a
    /// device to ask.
    let folder: @Sendable () throws -> URL
    /// How requests reach the recorder at an address, asked for only by a run that asks the recorder.
    let transport: @Sendable (_ host: String) -> any HTTPTransport
    /// How requests reach the television at an address: a transport that keeps no cookies of its own, since the
    /// client sends its registration's by hand (`Surroundings.tvTransport`).
    let tvTransport: @Sendable (_ host: String) -> any HTTPTransport
    /// Where the television's registration is kept (`Surroundings.tvCredentials`).
    let tvCredentials: any TVCredentialStore
    /// What a run posts and takes away for the reader to see.
    let notifications: Notifications

    public init(defaults: UserDefaults, folder: @escaping @Sendable () throws -> URL,
                transport: @escaping @Sendable (_ host: String) -> any HTTPTransport,
                tvTransport: @escaping @Sendable (_ host: String) -> any HTTPTransport,
                tvCredentials: any TVCredentialStore, notifications: Notifications) {
        self.defaults = defaults
        self.folder = folder
        self.transport = transport
        self.tvTransport = tvTransport
        self.tvCredentials = tvCredentials
        self.notifications = notifications
    }

    /// The cache, opened directly: the one the screens open (`Storage.guidePath(demo:in:)`), or nil when the
    /// folder or the database cannot be opened.
    func openGuide() -> GuideStore? {
        guard let path = try? Storage.guidePath(demo: DemoData.on(in: defaults), in: folder()) else { return nil }
        return try? GuideStore(path: path)
    }
}
