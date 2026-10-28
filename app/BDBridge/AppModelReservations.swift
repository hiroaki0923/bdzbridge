import Foundation
import RecorderKit
import SwiftUI

/// Reservations: the list and its orders, what marks a programme in the guide, making, changing and
/// cancelling one, and the queue of those waiting for the recorder.
///
/// Each device's are read, made, changed and deleted by its driver, and kept by its host (`RecorderHost`,
/// `TVHost`), in six entries written once for both (`DeviceHost`): here the two lists are only put together for
/// the screens, and a change or a delete is handed to the host of the device that holds the row
/// (`Reservation.device`), before anything else is done. So is a waiting reservation the reader asks to have
/// sent again, to the device it waits for (`PendingReservation.target`). What a new one would clash with is the
/// recorder's driver's alone (`RecorderDriver.conflicts`).
///
/// Making one is the same from a screen whichever device it is for: where a reservation of a programme can
/// still go (`destinations(for:)`), and one entry that reserves on the device named and on no other, and
/// answers in the one value both devices give (`reserve(_:on:quality:repeating:)`).
extension AppModel {
    /// The recorder's reservations read, as a screen that shows them does when it appears
    /// (`DeviceHost.loadReservations`), after `start()`.
    func loadReservations() async {
        await recorderHost.loadReservations()
    }

    /// The same, handing back the list read now, nil when none was, after `start()` as every entry of a host's
    /// is (`DeviceHost.readReservations`). The driver's read (`RecorderDriver.reservations`), kept on what the
    /// recorder said as the entry began (`RecorderSaid.keep`): a list read for a recorder let go of meanwhile --
    /// another answered or was chosen while the read was out -- is kept where no screen reads it, and the one
    /// after it, whose own connect reads its list (`RecorderHost.reached`), is left alone. The television's lists
    /// go with their host by the same rule (`TVHost`).
    @discardableResult
    func readReservations() async -> [Reservation]? {
        await recorderHost.readReservations()
    }

    /// A device's reservations read, as a screen that shows them does when it appears: the television's in a
    /// task of their own beside the recorder's. Nothing with no television in play.
    func loadReservations(of device: DeviceSlot) async {
        await deviceHost(for: device)?.loadReservations()
    }

    /// Since when the recorder's list on screen is old, for the screens to say so, by the one rule both hosts
    /// keep (`DeviceHost.staleSince`): here also while it is connected from an attach before a reconnect it
    /// answered without saying which it is, which cannot be asked either.
    var reservationsStaleSince: Date? { recorderHost.staleSince }

    /// Since when a device's list on screen is old (`DeviceHost.staleSince`); nil with no television in play.
    func staleSince(for device: DeviceSlot) -> Date? {
        deviceHost(for: device)?.staleSince
    }

    /// What pulling the recorder's reservations down asks for: what waits sent and then the list read, or a
    /// connect when the app is not connected, which does both once the recorder has answered -- the driver's to
    /// decide, once (`RecorderDriver.refreshReservations`), after `start()` whichever it does. The driver asks
    /// for the sending through the recorder's host, as an attach does (`sendWhatWaits`), which puts what it came
    /// to on the strip. The list it hands back is kept on what was said as this began (`RecorderSaid.keep`).
    func refreshReservations() async {
        await recorderHost.refreshReservations()
    }

    /// Pulling the reservations' tab down, which is the reader asking, and the one thing that gets another go at
    /// a recorder the app is not connected to, and at a television: both devices side by side, so that neither
    /// device's silence holds the other's list up.
    func pullDownReservations() async {
        async let television: Void? = tvHost?.refreshReservations()
        await refreshReservations()
        await television
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
        guard let key = ByProgram.key(program) else { return nil }
        return reservationsByProgram[key] ?? tvHost?.reservationsByProgram[key]
    }

    /// Every reservation that follows this programme, one for each device that holds one, the recorder's
    /// first: for whatever has to say on which device a programme is set to record.
    func reservations(for program: GuideProgramRow) -> [Reservation] {
        guard let key = ByProgram.key(program) else { return [] }
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
        guard let key = ByProgram.key(program) else { return nil }
        return pendingByProgram[key]
    }

    /// The reservation of `program` waiting for `device`, if there is one. One programme can wait for both
    /// devices, a row for each: `pending(for:)` stays the first of them, which is all the guide's mark
    /// needs.
    func pending(for program: GuideProgramRow, on device: DeviceSlot) -> PendingReservation? {
        guard let key = ByProgram.key(program) else { return nil }
        return ByProgram.of(pending.filter { $0.target == device })[key]
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
    /// one value both devices answer with (`Reserved`). It goes to the device named and to no other, by its
    /// host (`DeviceHost.reserve`).
    ///
    /// A television's is handed over before anything else: the recorder is asked nothing on its account, not
    /// its check, and its line is not touched. Its host opens the cache first, as the recorder's does. A
    /// television records in its one mode (`TVDriver.recordsIn`) and has no disk to choose, so `quality` and
    /// `disk` are not read for one. With no television in play, as in the demo before its television is added,
    /// nothing is kept and nothing sent.
    ///
    /// The recorder's is its driver's (`RecorderDriver.reserve`): made; kept on the phone, waiting -- with no
    /// reason when the recorder cannot be asked or passed it over, with the recorder's reason when it turned it
    /// down, or held after silence at its create; or not done with its reason, the driver's result saying which;
    /// with no driver, that the app is not connected. The list it hands back after a reservation made is kept on
    /// what was said as this began (`RecorderSaid.keep`): a reservation for a recorder let go of meanwhile leaves
    /// the list of the one after it alone. What follows a reservation on either device is its host's
    /// (`DeviceHost.afterAReservation`): the warning of the runs with no screen, and the system's dialog about
    /// notifications.
    func reserve(_ program: GuideProgramRow, on device: DeviceSlot, quality: String,
                 repeating: String, disk: String = RecorderDisk.internalID) async -> Reserved {
        await deviceHost(for: device)?
            .reserve(program, .reserving(quality: quality, repeating: repeating, disk: disk))
            ?? .notDone(device.notConnected)
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
    /// phone, unsent. Nothing is done while the device the row waits for works. Its swipe is held back by the
    /// same, but the question was up for as long as the reader took, and a sending begun meanwhile has the row
    /// in hand and would go on to make it, after the reader was told that it is not sent. Taking the television
    /// away does nothing then either (`takeTheTelevisionAway`). Neither device's work holds back the other's
    /// rows.
    ///
    /// That guard sees the app's own work only. A run with no screen -- the Shortcuts action, the overnight
    /// run -- sends through the same queue with a client of its own, so a row is deleted by its device's driver
    /// in the queue's turn (`TVDriver.deleteWaiting`, `RecorderDriver.deleteWaiting`), which says whether a
    /// sending whose turn came first made it. That the action shares the queue is Apple's word, not seen on a
    /// phone: it is an intent in the app's own target, which Apple's session "Dive into App Intents" (WWDC22)
    /// says needs no coordinating "across processes" and is run, in the background, by the app itself launched
    /// "in a special mode without scenes"; the article "Creating your first app intent" puts the other way as
    /// "You can also place your app intent types in an app extension, and run them in a separate process from
    /// the rest of your app."
    ///
    /// The television's driver is handed what the app holds as it stands in the turn: the phone's queue, the list of
    /// the television in play, read by its host, which keeps it for the screens (`DeviceHost.readReservationsNow`), and
    /// whether one is in play. The recorder's driver hands back the list it read in the turn, kept on what was said as
    /// the delete began (`RecorderSaid.keep`). A row made is not deleted, and what is handed back in place of that says
    /// it was made before the delete and where to delete the reservation (`TVDriver.madeBeforeItsDelete`,
    /// `RecorderDriver.madeBeforeItsDelete`), not the strip's sentence for a row sent. So a row has one delete at a
    /// time: a second one, asked for while the first waits its turn -- the row is still listed then, and the reader can
    /// confirm again -- would find the row gone and say it was made, and it comes back with nil at once instead. The
    /// warning of reservations not yet at the television is taken away once none of its rows waits
    /// (`forgetTheWarningOnceSent`), and so is the recorder's (`forgetTheRecordersWarningOnceSent`).
    ///
    /// Nil when the row was deleted, when nothing was done while its device works or while the row has a
    /// delete under way already, and when the row has gone and nothing says it was made.
    @discardableResult
    func deleteWaiting(_ waiting: PendingReservation) async -> String? {
        guard !isBusy(for: waiting.target) else { return nil }
        guard deletingWaiting.insert(waiting.id).inserted else { return nil }
        defer { deletingWaiting.remove(waiting.id) }
        guard waiting.target == .tv else { return await recorderHost.deleteWaiting(waiting) }
        let made = await TVDriver.deleteWaiting(waiting, queue: { self.store },
                                                listing: { await self.tvHost?.readReservationsNow() },
                                                inPlay: { self.tvHost != nil },
                                                queueWritten: { await self.loadPending() }) ?? false
        await loadPending()
        forgetTheWarningOnceSent()
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
    /// connected; to a recorder given up on, by the attach of a connect asked for here; and otherwise with the
    /// rest the next time the recorder answers: the driver's steps (`RecorderDriver.resend`). The list read
    /// after a sending is kept on what was said as this began (`RecorderSaid.keep`), and what the round came to
    /// goes on the strip (`RecorderHost.tellTheStrip`). What the row came to is handed back, as the driver says
    /// it, nil where there is nothing to say of the row. A warning the runs with no screen left of reservations
    /// not yet at the recorder goes once none of them waits to go (`forgetTheRecordersWarningOnceSent`).
    ///
    /// A row waiting for the television is its host's to send again, handed over first as a change or a
    /// delete of a television's reservation is (`change`, `cancel`): nothing below is for it. The recorder is
    /// not made sure of on its account, and it takes no turn in the recorder's sending. With no television in
    /// play nothing is done, and the row keeps its reason.
    @discardableResult
    func resend(_ waiting: PendingReservation) async -> Reserved? {
        await deviceHost(for: waiting.target)?.resend(waiting)
    }

    /// 「もう一度送る」 as a screen asks for it: the row is sent again (`resend`), and what it came to is
    /// handed back for that screen to say what the strip does not, whichever device the row waits for.
    func sendAgain(_ waiting: PendingReservation) async -> Reserved? {
        await resend(waiting)
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
        PendingQueue.whatWaits(for: Set(pending.map(\.target)), anyHeld: pending.contains { $0.problem != nil },
                               diskAway: tvWaitsForItsDisk)
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
    /// it hands back is kept on what was said as this began (`RecorderSaid.keep`): a change for a recorder let go
    /// of meanwhile leaves the list of the one after it alone. What it came to is the driver's result: done, with
    /// nothing to add; or not done, with its reason. With no driver, or a row the driver turns away as no
    /// recorder's, which no screen holds, it is not done, the app not being connected.
    func change(_ reservation: Reservation, quality: String, repeating: String,
                disk: String? = nil) async -> Altered {
        await deviceHost(for: reservation.device)?
            .change(reservation, .changing(quality: quality, repeating: repeating, disk: disk))
            ?? .notDone(reservation.device.notConnected)
    }

    /// Deletes one reservation, as the device that holds it holds it now. What it came to, in the one value both
    /// devices answer with (`Altered`), for the screen that asked to say.
    ///
    /// A television's reservation is its host's to delete, handed over first as for a change (`change`). With no
    /// television in play nothing is sent, and the answer is that the app is not connected to it.
    ///
    /// The recorder's is its driver's (`RecorderDriver.cancel`): the list read again first and the reservation
    /// found in it, the delete sent once, and the row taken out of the list read after it. The list it hands back
    /// is kept on what was said as this began (`RecorderSaid.keep`): a delete for a recorder let go of
    /// meanwhile does not touch the list of the one after it, which may hold another row under the same number.
    /// What it came to is the driver's result, the reason with it; with no driver, that the app is not connected.
    @discardableResult
    func cancel(_ reservation: Reservation) async -> Altered {
        await deviceHost(for: reservation.device)?.cancel(reservation) ?? .notDone(reservation.device.notConnected)
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
