import Foundation
import RecorderKit

/// What the app does with no screen behind it -- the overnight run and the Shortcuts action's sending -- with
/// its surroundings handed in, and what the action says it came to. The entries the system calls, which hand
/// in the app's own, are in `BackgroundWork.swift`.
public enum BackgroundWork {
    /// The next 02:00 in the recorder's own time zone (`GuideRefresh.nextNightlyRun`). The box rebuilds its guide
    /// files around 00:49.
    public static func nextNightlyRun(after now: Date = Date()) -> Date {
        GuideRefresh.nextNightlyRun(after: now)
    }

    /// Whether a television is saved beside the recorder, for what runs with no screen and so has no model to
    /// ask: read from what the screens saved, as the recorder's address is. With one saved, what became of the
    /// recorder's queue says which device it went to (`Notify.queueFlushed`, `BackgroundWork.saying`), and
    /// the television's part tells nothing of a television taken away while it was out. The defaults are handed
    /// in for a test of the reading; a run reads the app's own.
    public static func televisionSaved(in defaults: UserDefaults = .standard) -> Bool {
        !(defaults.string(forKey: DefaultsKey.tvHost) ?? "").isEmpty
    }

    /// The same with its surroundings handed in, which is what the tests give it: the run, the queue read
    /// after it, and what that tells against what was told before (`ToldOnce.after`), which `told` reads, with
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

    /// The same with its surroundings handed in, which is what the tests give it. They hand it no MAC, for
    /// the reason they hand `sendWaiting` none.
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

    /// The same with its surroundings handed in, which is what the tests give it. They hand it no MAC: the
    /// packet goes out from here (`packet`) and not through `Surroundings`, so one handed in is sent on
    /// whatever network the tests are run on.
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
    /// is read, kept or written here: what is told once is the entry's (`BackgroundWork.sendWaiting`), and
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
