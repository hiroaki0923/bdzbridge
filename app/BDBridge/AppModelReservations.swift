import Foundation
import RecorderKit
import SwiftUI

/// Reservations: the list and its orders, what marks a programme in the guide, making, changing and
/// cancelling one, and the queue of those waiting for the recorder.
///
/// The recorder's are read, made, changed and deleted by its driver, what waits for it is sent there too, and
/// what a new one would clash with is asked there (`RecorderDriver`): here the app asks, and keeps what comes
/// back. A television's are its host's (`TVHost`), which keeps them apart from the recorder's:
/// here the two lists are only put together for the screens, and a change or a delete is sent to the device
/// that holds the row (`Reservation.device`), before anything else is done. So is a waiting reservation the
/// reader asks to have sent again, to the device it waits for (`PendingReservation.target`).
///
/// Making one is the same from a screen whichever device it is for: where a reservation of a programme can
/// still go (`destinations(for:)`), and one entry that reserves on the device named and on no other, and
/// answers in the one value both devices give (`reserve(_:on:quality:repeating:)`).
extension AppModel {
    func loadReservations() async {
        await loadReservations(since: timesForgotten)
    }

    /// The same for an entry that noted `timesForgotten` as it began: the driver's read
    /// (`RecorderDriver.reservations`), kept by that count (`keepReservations`), and handed back, nil when
    /// nothing was read.
    @discardableResult
    func loadReservations(since forgotten: Int) async -> [Reservation]? {
        await start()
        let read = await recorderDriver?.reservations()
        keepReservations(read, since: forgotten)
        return read
    }

    /// Puts a list of the recorder's reservations on the screens, one read on behalf of an entry that noted
    /// `timesForgotten` as `forgotten` when it began: only while the count is still that. A list read for a
    /// recorder let go of meanwhile -- another answered or was chosen while the read was out -- is not put on
    /// the screens of the one after it, whose own connect reads its list (`reached`). The television's lists go
    /// with their host by the same rule (`TVHost`). Nil, nothing read, leaves the list as it was, and its time.
    /// A list kept was read now, and its time is put down with it (`reservationsRead`).
    func keepReservations(_ list: [Reservation]?, since forgotten: Int) {
        guard let list, timesForgotten == forgotten else { return }
        reservations = list
        reservationsRead = Date()
    }

    /// Since when the recorder's list on screen is old, for the screens to say so, as a television's
    /// (`TVHost.staleSince`): the time it was read, while it has rows and nothing can be asked of the recorder
    /// now (`RecorderDriver.canBeAsked`) -- not connected, given up on after silence, or connected from an
    /// attach before a reconnect it answered without saying which it is. Nil while it can be asked, since the
    /// list is then read as a screen appears; and nil with no rows, when nothing old is shown. Nil too while a
    /// connect to a recorder that answered last time is under way: the list is read as that connect gets there,
    /// and it is old only once the connect has failed.
    var reservationsStaleSince: Date? {
        guard !reservations.isEmpty, recorderDriver?.canBeAsked != true else { return nil }
        if session.connecting, session.connected { return nil }
        return reservationsRead
    }

    /// What pulling the reservations down asks for: the list read again and what waits sent, or a connect when
    /// the app is not connected, which does both once the recorder has answered -- the driver's to decide, once
    /// (`RecorderDriver.refreshReservations`), after `start()` whichever it does. The list it hands back is kept
    /// by the count noted here (`keepReservations`), and what the sending came to goes on the strip
    /// (`tellTheStrip`).
    func refreshReservations() async {
        let forgotten = timesForgotten
        await start()
        guard let pulled = await recorderDriver?.refreshReservations() else { return }
        keepReservations(pulled.list, since: forgotten)
        tellTheStrip(pulled.round)
    }

    enum ReservationSort: String, CaseIterable {
        case time, genre, channel

        var label: String {
            switch self {
            case .time: "日時"
            case .genre: "ジャンル"
            case .channel: "局"
            }
        }
    }

    /// The recorder keeps its own automatic recordings alongside the ones an app put in, and so does Sony's
    /// app: two lists rather than one.
    enum ReservationKind: String, CaseIterable {
        case all, mine, automatic

        var label: String {
            switch self {
            case .all: "すべて"
            case .mine: "通常の予約"
            case .automatic: "おまかせ"
            }
        }
    }

    struct ReservationSection: Identifiable {
        var title: String
        var items: [Reservation]
        var id: String { title }
    }

    /// The reservations of both devices, the recorder's first, whichever kind is shown and in no order of the
    /// list's: put together each time they are read, and kept apart where they are held, since a read of
    /// either replaces its own list whole. For the screens that look through every row: the search, and
    /// whether there is anything to show at all.
    var allReservations: [Reservation] { reservations + (tvHost?.reservations ?? []) }

    /// What the list shows. A television's reservation has no creator, so it is among 通常の予約 and never
    /// among おまかせ.
    var shownReservations: [Reservation] {
        switch reservationKind {
        case .all: allReservations
        case .mine: allReservations.filter { !$0.createdByRecorder }
        case .automatic: allReservations.filter(\.createdByRecorder)
        }
    }

    /// One row of the list by what tells its rows apart (`Reservation.listKey`), whichever kind is shown: a
    /// row picked on the screen, found again as it is held now. Not by its id, which the two devices each
    /// number for themselves.
    func reservation(listKey: String) -> Reservation? {
        allReservations.first { $0.listKey == listKey }
    }

    /// Reservations under a heading: the day they record on, or the genre, or the channel. Soonest first
    /// within each, since a reservation is something that has not happened yet.
    var reservationSections: [ReservationSection] {
        let byStart = shownReservations.sorted { $0.start < $1.start }
        switch reservationSort {
        case .time:
            return sections(byStart) { Format.day.string(from: $0.start) }
        case .genre:
            return sections(byStart.sorted { key($0) < key($1) }) {
                $0.genreCode.flatMap { Codes.genreLabel[$0 / 16] } ?? "ジャンルなし"
            }
        case .channel:
            return sections(byStart.sorted { ($0.serviceID, $0.start) < ($1.serviceID, $1.start) }) {
                self.channelName(for: $0)
            }
        }
    }

    private func key(_ reservation: Reservation) -> (Int, Date) {
        (reservation.genreCode ?? 0xFF * 16, reservation.start)
    }

    /// Keeps the headings in the order they first appear, so the sort decides the order of the sections too.
    private func sections(_ reservations: [Reservation],
                          by heading: (Reservation) -> String) -> [ReservationSection] {
        var order: [String] = []
        var grouped: [String: [Reservation]] = [:]
        for reservation in reservations {
            let title = heading(reservation)
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(reservation)
        }
        return order.map { ReservationSection(title: $0, items: grouped[$0] ?? []) }
    }

    /// The reservation that follows this programme, if there is one: the recorder's, or the television's when
    /// the recorder has none, which is all the guide's mark needs to know. Time-only reservations carry no
    /// programme id and so cannot be matched to one.
    func reservation(for program: GuideProgramRow) -> Reservation? {
        guard let key = Self.key(program) else { return nil }
        return reservationsByProgram[key] ?? tvHost?.reservationsByProgram[key]
    }

    /// Every reservation that follows this programme, one for each device that holds one, the recorder's
    /// first: for whatever has to say on which device a programme is set to record.
    func reservations(for program: GuideProgramRow) -> [Reservation] {
        guard let key = Self.key(program) else { return [] }
        return [reservationsByProgram[key], tvHost?.reservationsByProgram[key]].compactMap { $0 }
    }

    /// The other reservations whose hours overlap this one's, soonest first, for a reservation the recorder
    /// marks 重複, which says that something clashes but not with what. The sheet names them as reservations at
    /// the same time rather than as the clash itself: the recorder has more than one tuner, so hours in common
    /// are not by themselves what it is complaining about. Only among the reservations of the device that
    /// holds this one: what another device records at the same hour is in nobody's way.
    func overlapping(_ reservation: Reservation) -> [Reservation] {
        (reservation.device == .tv ? tvHost?.reservations ?? [] : reservations)
            .filter { $0.id != reservation.id && $0.start < reservation.end && reservation.start < $0.end }
            .sorted { $0.start < $1.start }
    }

    /// The reservation for this programme that is waiting to be sent, if there is one. Queued from the guide,
    /// so it always carries the programme id.
    func pending(for program: GuideProgramRow) -> PendingReservation? {
        guard let key = Self.key(program) else { return nil }
        return pendingByProgram[key]
    }

    /// The reservation of `program` waiting for `device`, if there is one. One programme can wait for both
    /// devices, a row for each: `pending(for:)` stays the first of them, which is all the guide's mark
    /// needs.
    func pending(for program: GuideProgramRow, on device: DeviceSlot) -> PendingReservation? {
        guard let key = Self.key(program) else { return nil }
        return Self.byProgram(pending.filter { $0.target == device })[key]
    }

    /// Where a reservation can be made: the recorder alone until a television is saved -- in the demo, until
    /// the demo's is added (`makeTVLink`); both with both; and the television alone where a television is
    /// saved and no recorder is.
    var destinations: [DeviceSlot] {
        tv == nil ? [.recorder] : host.isEmpty ? [.tv] : [.recorder, .tv]
    }

    /// The devices a new reservation of `program` can still go to: each of `destinations` that neither
    /// holds the programme nor has a reservation of it waiting, where a second would be the same one again
    /// or replace the row that waits. And a television only while its driver takes the programme
    /// (`TVDriver.whyNot`), which it does until the programme is over: one that has begun is offered a
    /// television as it is the recorder, and a screen that offers what is listed here offers nothing
    /// `reserve` turns away at the television's door. The recorder is listed whatever the programme's
    /// time; that a programme which is over is offered nowhere is the sheet's own check, as it was.
    func destinations(for program: GuideProgramRow) -> [DeviceSlot] {
        let holding = reservations(for: program).map(\.device)
        return destinations.filter { device in
            !holding.contains(device) && pending(for: program, on: device) == nil
                && (device != .tv || TVDriver.whyNot(program) == nil)
        }
    }

    private static func key(_ program: GuideProgramRow) -> String? {
        Codes.broadcasting[program.broadcasting].map { key($0, program.serviceID, program.eventID) }
    }

    private static func key(_ broadcastingType: Int, _ serviceID: Int, _ eventID: Int) -> String {
        "\(broadcastingType)-\(serviceID)-\(eventID)"
    }

    static func byProgram(_ reservations: [Reservation]) -> [String: Reservation] {
        Dictionary(reservations.compactMap { reservation in
            reservation.eventID.map { (key(reservation.broadcastingType, reservation.serviceID, $0), reservation) }
        }, uniquingKeysWith: { first, _ in first })
    }

    static func byProgram(_ pending: [PendingReservation]) -> [String: PendingReservation] {
        Dictionary(pending.compactMap { waiting in
            waiting.request.eventID.map {
                (key(waiting.request.broadcastingType, waiting.request.serviceID, $0), waiting)
            }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The disk a reservation's row names, or nil for none: the one rule (`RecorderDisk.shown`), so that only a
    /// recorder's row off the internal disk names one, after the disk known in the slot.
    func diskShown(_ reservation: Reservation) -> String? {
        RecorderDisk.shown(reservation.destination, on: reservation.device, usb: usbDisk)
    }

    /// The same for a row that waits, by the device it waits for: a television's carries the internal disk's id,
    /// which nothing sending to the television reads.
    func diskShown(_ waiting: PendingReservation) -> String? {
        RecorderDisk.shown(waiting.request.destination, on: waiting.target, usb: usbDisk)
    }

    /// Reservations that would clash, as a programme's sheet asks as it opens: the recorder's driver asks the
    /// recorder with the very payload a reservation of `program` would send to `disk`, the disk the sheet shows
    /// (`RecorderDriver.conflicts`). Nil when it was not asked or its answer could not be had; what there was to
    /// say of that is on the recorder's line.
    func conflicts(for program: GuideProgramRow, quality: String, repeating: String,
                   disk: String = RecorderDisk.internalID) async -> [Reservation]? {
        await start()
        return await recorderDriver?.conflicts(for: program, quality: quality, repeating: repeating, disk: disk)
    }

    /// What the programme's sheet asks: a reservation of `program` on `device`, and what it came to, in the
    /// one value both devices answer with (`Reserved`). It goes to the device named and to no other.
    ///
    /// A television's is its host's, and is handed over before anything else: nothing below is for it,
    /// whatever state the recorder is in. The recorder is asked nothing on its account, not its check,
    /// and its line is not touched. A television records in its one mode (`TVDriver.recordsIn`), so
    /// `quality` is not read. With no television in play, as in the demo before its television is added,
    /// nothing is kept and nothing sent.
    ///
    /// The recorder's is its driver's (`RecorderDriver.reserve`): made, kept on the phone when the recorder
    /// cannot be asked, or not done with the recorder's line, the driver's result saying which. The list it
    /// hands back after a reservation made is kept by the count noted here (`keepReservations`): a reservation
    /// for a recorder let go of meanwhile leaves the list of the one after it alone. A television has no disk to
    /// choose, and `disk` is not read for one.
    ///
    /// A reservation kept for the recorder is heard of again in a notification once it is sent, so the system's
    /// dialog comes here, as it comes in the television's host (`TVHost.reserve`): after the row is kept, before
    /// the result is said, and once the reservation's line is down. The dialog waits on the reader, who may
    /// leave the app instead of answering, and neither the reservation nor the app's work waits with it.
    func reserve(_ program: GuideProgramRow, on device: DeviceSlot, quality: String,
                 repeating: String, disk: String = RecorderDisk.internalID) async -> Reserved {
        if device == .tv {
            await start()
            return await tvHost?.reserve(program, repeating: repeating) ?? .notDone(TVDriver.notConnected)
        }
        let forgotten = timesForgotten
        await start()
        guard let came = await recorderDriver?.reserve(program, quality: quality, repeating: repeating, disk: disk)
        else { return .notDone(problem ?? RecorderDriver.returnedAnError) }
        keepReservations(came.list, since: forgotten)
        if case .waiting = came.reserved { await askForNotifications() }
        return came.reserved
    }

    // MARK: - reservations waiting for the recorder

    func loadPending() async {
        guard let store else { return }
        pending = (try? await store.pendingReservations()) ?? []
    }

    func removePending(_ waiting: PendingReservation) async {
        guard let store else { return }
        try? await store.removePending(waiting.id)
        await loadPending()
    }

    /// 削除する as the reservations tab's question about a waiting row asks for it: the row is taken off the
    /// phone, unsent (`removePending`). For a television's row nothing is done while the television works.
    /// Its swipe is held back by the same, but the question was up for as long as the reader took, and a
    /// sending begun meanwhile has the row in hand and would go on to make it, after the reader was told
    /// that it is not sent. Taking the television away does nothing then either (`takeTheTelevisionAway`).
    /// Never for the recorder's work, and a recorder's row is deleted whatever is under way, as it always
    /// has been.
    ///
    /// That guard sees the app's own work only. A run with no screen -- the Shortcuts action, the overnight
    /// run -- sends through the same queue with a client of its own, so a television's row is deleted in the
    /// queue's turn (`PendingQueue.betweenFlushes`): before a sending, which then does not see it, or after
    /// one. The wait is the length of a round, a recorder's included. That the action shares the queue is
    /// inferred, not seen: it is an intent in the app's own target, and Apple's article "Creating your first
    /// app intent" says only "You can also place your app intent types in an app extension, and run them in a
    /// separate process from the rest of your app."
    ///
    /// A sending whose turn came first may have made the row, and then it is not deleted: said to be, it
    /// would be a reservation on the television that the reader believes gone. What to say in place of that
    /// is handed back, as the strip says a row sent (`TVDriver.madeBeforeItsDelete`). It was made when the
    /// television's list, read in the turn and before anything is deleted, holds its programme -- though the
    /// row still waited, as one does whose create the television took and whose answer was lost: that row
    /// leaves the queue as a row made does. And it was made when the sending took it out of the queue though
    /// its programme is not over, whatever the list read gave, since a list that cannot be read now says
    /// nothing: while the television is in play, nothing else takes such a row out but a round that made it
    /// or found it there, and a delete of the app's own. So a row has one delete at a time: a second one,
    /// asked for while the first waits its turn -- the row is still listed then, and the reader can confirm
    /// again -- would find the row gone and say it was made, and it comes back with nil at once instead. The
    /// list read is kept for the screens either way, and the warning of reservations not yet at the
    /// television is taken away once none of its rows waits (`forgetTheWarningOnceSent`).
    ///
    /// What it cannot tell: a row whose create the television took and whose answer was lost is deleted
    /// unsent, with nothing said, when the app's own link cannot read the list -- as it often cannot, a
    /// television that was silent to the action being silent to the app as well -- and the television keeps
    /// the reservation.
    ///
    /// Nil when the row was deleted, when nothing was done while the television works or while the row has
    /// a delete under way already, and when the row has gone and nothing says it was made.
    @discardableResult
    func deleteWaiting(_ waiting: PendingReservation) async -> String? {
        guard !(waiting.target == .tv && isBusy(for: .tv)) else { return nil }
        guard waiting.target == .tv else {
            await removePending(waiting)
            return nil
        }
        guard deletingWaiting.insert(waiting.id).inserted else { return nil }
        defer { deletingWaiting.remove(waiting.id) }
        let made = await PendingQueue.betweenFlushes { @MainActor in
            // A queue that cannot be read is no sign that a sending took the row: the delete is tried.
            let stillWaits = (try? await self.store?.pendingReservations())
                .map { rows in rows.contains { $0.id == waiting.id } } ?? true
            let listed = await self.tvHost?.readReservations() ?? []
            let onTheTelevision = waiting.request.eventID.map {
                AppModel.byProgram(listed)[AppModel.key(waiting.request.broadcastingType, waiting.request.serviceID,
                                                        $0)] != nil
            } ?? false
            let made = onTheTelevision || (!stillWaits && waiting.request.end >= Date() && self.tvHost != nil)
            if stillWaits { await self.removePending(waiting) }
            return made
        } ?? false
        await loadPending()
        await forgetTheWarningOnceSent()
        return made ? TVDriver.madeBeforeItsDelete(waiting, naming: DeviceSlot.tv.label) : nil
    }

    /// ［それでも予約］ at the question a screen asks before a reservation that would stop others from
    /// recording is made all the same (`Reserved.wouldStop`): the held row sent again, which is the
    /// reader's consent to the reason on it, as the question showed it, and to no other. What that came to
    /// is handed back for the screen to say, and can be the same question again, about what the television
    /// names by then. After a reservation the reader has just asked for (`askedForJustNow`) nothing of it
    /// goes on the strip: the row never waited, and is said as the reservation it is. A row that was
    /// waiting before is said there as any row sent again is (`sendAgain`).
    func consent(to held: PendingReservation, askedForJustNow: Bool) async -> Reserved? {
        await tvHost?.resend(held, neverWaited: askedForJustNow)
    }

    /// ［キャンセル］ at that question. Nothing is made either way, and what becomes
    /// of the row goes by where the question came from. After a reservation the reader has just asked for
    /// (`askedForJustNow`) the row is taken off the phone: it is there only because a reservation is kept
    /// before the television is asked anything, and a no that left it waiting in red would not be a no. A
    /// row that was waiting before, sent again from where it is shown, is left as it was, with its reason:
    /// not making it now is not asking for it to be deleted.
    ///
    /// Not held back by the television's work, as the tab's delete of a waiting row is (`deleteWaiting`):
    /// the row carries its reason, and no sending makes such a row without the consent declined here.
    func decline(_ held: PendingReservation, askedForJustNow: Bool) async {
        guard askedForJustNow else { return }
        await removePending(held)
    }

    /// Sends one the recorder refused once more, because the reader has asked. A refused reservation is not
    /// sent again by itself (`PendingQueue.flush`), but the reason can go away -- a channel subscribed to
    /// since, an antenna put right -- and only the reader knows when it has. Sent now when the app is
    /// connected, and otherwise with the rest the next time the recorder answers: the driver's steps
    /// (`RecorderDriver.resend`). The list read after a sending is kept by the count noted here
    /// (`keepReservations`), and what the round came to goes on the strip (`tellTheStrip`).
    ///
    /// A row waiting for the television is its host's to send again, handed over first as a change or a
    /// delete of a television's reservation is (`change`, `cancel`): nothing below is for it. The recorder is
    /// not made sure of on its account, and it takes no turn in the recorder's sending. With no television in
    /// play nothing is done, and the row keeps its reason.
    func resend(_ waiting: PendingReservation) async {
        if waiting.target == .tv {
            await tvHost?.resend(waiting)
            return
        }
        let forgotten = timesForgotten
        await start()
        guard let sent = await recorderDriver?.resend(waiting) else { return }
        keepReservations(sent.list, since: forgotten)
        tellTheStrip(sent.round)
    }

    /// 「もう一度送る」 as a screen asks for it: the row is sent again (`resend`), and what it came to is
    /// handed back for that screen to say what the strip does not. A television's row is answered by its
    /// host. A recorder's is sent as it has always been, and says what it sent on the strip and nowhere
    /// else: nothing comes back for it.
    func sendAgain(_ waiting: PendingReservation) async -> Reserved? {
        if waiting.target == .tv { return await tvHost?.resend(waiting) }
        await resend(waiting)
        return nil
    }

    /// The word for the device a waiting row is for, where a row has to say it: with a television saved, or
    /// for a row that is not the recorder's. Nil in a home with a recorder alone, whose rows read as they
    /// always have.
    func deviceSaid(for waiting: PendingReservation) -> String? {
        tv != nil || waiting.target != .recorder ? waiting.target.label : nil
    }

    /// What the reservations tab says under what waits: by the devices its rows wait for and not by the
    /// devices saved, so that the recorder's rows alone are said as they always have been, a television
    /// saved or not. Then how a row with a reason is sent again, while any has one. And last, while a row
    /// waits for the television's disk to come back, that the disk is away (`tvWaitsForItsDisk`): of such
    /// a row the sentences before it say only that it goes when the television is next connected to, and
    /// the television may well be connected. The strip says the same, but as the last of its lines, where
    /// it can sit behind whatever the recorder has up.
    var whatWaitsSays: String {
        let devices = Set(pending.map(\.target))
        let waits = devices == [.tv] ? Self.notYetAtTheTelevision
            : devices.contains(.tv) ? Self.notYetAtEither : Self.notYetAtTheRecorder
        return waits + (pending.contains { $0.problem != nil } ? Self.reasonsWaitForTheReader : "")
            + (tvWaitsForItsDisk ? TVDriver.diskNotFound + "。" : "")
    }

    private static let notYetAtTheRecorder = "レコーダーに届かなかった予約です。次にレコーダーにつながったときに登録します。"
    private static let notYetAtTheTelevision = "テレビにまだ届いていない予約です。次にテレビにつながったときに登録します。"
    private static let notYetAtEither = "レコーダーやテレビにまだ届いていない予約です。"
        + "それぞれ、次につながったときに登録します。"
    private static let reasonsWaitForTheReader = "理由が付いているものは自動では送り直しません。"
        + "右にスワイプすると、もう一度送れます。"

    /// What a sending of what waits for the recorder came to, on the strip: only when a round ran
    /// (`RecorderDriver.sendWhatWaits`), and nothing when none did -- no row for the recorder, or the recorder
    /// not there to send to. Said on screen, since a notification does not show while the app is in front
    /// (nothing here answers `willPresent`). A round with nothing to say -- everything waiting had been refused
    /// before -- leaves the last line where it was. What is held for another recorder is said each time, for as
    /// long as any is, and first (`RecorderDriver.heldBack`), counted from the rows on screen, which the driver
    /// has had read again after its round (`queueWritten`). What became of the queue says which device it went
    /// to once a television is saved beside the recorder, and not before (`PendingQueue.Outcome.said`).
    func tellTheStrip(_ round: PendingQueue.Outcome?) {
        guard let round else { return }
        let lines = [RecorderDriver.heldBack(in: pending), round.said(withATelevisionSaved: tv != nil)]
            .compactMap { $0 }
        if !lines.isEmpty { flushReport = lines.joined(separator: "。") }
    }

    /// What a reservation's sheet asks: a change of `reservation`, and what it came to, in the one value both
    /// devices answer with (`Altered`). It goes to the device that holds the row and to no other.
    ///
    /// A television's is its host's, and is handed over before anything else, whatever state the recorder is
    /// in: the recorder is asked nothing on its account, not its check, and its line is not touched. A
    /// television records in its one mode and has no disk to choose, so `quality` and `disk` are not read for
    /// one. With no television in play, as in the demo before its television is added, nothing is sent, and
    /// the answer is that the app is not connected to it.
    ///
    /// The recorder's is its driver's (`RecorderDriver.update`): the list read again first and the reservation
    /// found in it, the slot waited for when the change names the USB disk, and the change sent once. The list
    /// it hands back is kept by the count noted here (`keepReservations`): a change for a recorder let go of
    /// meanwhile leaves the list of the one after it alone. What it came to is the driver's result: done, with
    /// nothing to add; or not done, with the recorder's line -- what the sheet said before, in the same words. A
    /// row the driver turns away as no recorder's, which no screen holds, is not done with the line as it stands.
    func change(_ reservation: Reservation, quality: String, repeating: String,
                disk: String? = nil) async -> Altered {
        if reservation.device == .tv {
            return await tvHost?.update(reservation, repeating: repeating) ?? .notDone(TVDriver.notConnected)
        }
        let forgotten = timesForgotten
        await start()
        let came = await recorderDriver?.update(reservation, quality: quality, repeating: repeating, disk: disk)
        keepReservations(came?.list, since: forgotten)
        return came?.altered ?? .notDone(problem ?? RecorderDriver.returnedAnError)
    }

    /// Deletes one reservation, as the device that holds it holds it now. What it came to, in the one value both
    /// devices answer with (`Altered`), for the screen that asked to say.
    ///
    /// A television's reservation is its host's to delete, handed over first as for a change (`change`). With no
    /// television in play nothing is sent, and the answer is that the app is not connected to it.
    ///
    /// The recorder's is its driver's (`RecorderDriver.cancel`): the list read again first and the reservation
    /// found in it, the delete sent once, and the row taken out of the list read after it. The list it hands back
    /// is kept by the count noted here (`keepReservations`): a delete for a recorder let go of meanwhile does not
    /// touch the list of the one after it, which may hold another row under the same number. What it came to is
    /// the driver's result, the reason with it; with no driver, that the app is not connected.
    @discardableResult
    func cancel(_ reservation: Reservation) async -> Altered {
        if reservation.device == .tv {
            return await tvHost?.cancel(reservation) ?? .notDone(TVDriver.notConnected)
        }
        let forgotten = timesForgotten
        await start()
        guard let came = await recorderDriver?.cancel(reservation) else {
            return .notDone(RecorderDriver.notConnected)
        }
        keepReservations(came.list, since: forgotten)
        return came.deleted ?? .notDone(RecorderDriver.notConnected)
    }

    /// What to call the channel a reservation is on: the guide's name for it, and for a television's row on a
    /// channel the guide does not have, the name the television gave with the row.
    func channelName(for reservation: Reservation) -> String {
        channelNames["\(reservation.broadcastingType)-\(reservation.serviceID)"]
            ?? reservation.tvRow?.channelName.flatMap { $0.isEmpty ? nil : $0 }
            ?? Codes.broadcastingLabel[Codes.broadcasting(code: reservation.broadcastingType) ?? ""]
            ?? "不明な局"
    }

    /// The programme a reservation follows, when it is still in the cached guide.
    func program(for reservation: Reservation) async -> GuideProgramRow? {
        guard let store, let eventID = reservation.eventID,
              let broadcasting = Codes.broadcasting(code: reservation.broadcastingType) else { return nil }
        return try? await store.program(broadcasting: broadcasting, serviceID: reservation.serviceID,
                                        eventID: eventID)
    }
}
