import Foundation
import RecorderKit
import SwiftUI

/// Reservations: the list and its orders, what marks a programme in the guide, making, changing and
/// cancelling one, and the queue of those waiting for the recorder.
///
/// The recorder's are read, changed and deleted here. A television's are its host's (`TVHost`), which keeps
/// them apart from the recorder's: here the two lists are only put together for the screens, and a change or a
/// delete is sent to the device that holds the row (`Reservation.device`), before anything else is done. So is
/// a waiting reservation the reader asks to have sent again, to the device it waits for
/// (`PendingReservation.target`).
extension AppModel {
    func loadReservations() async {
        await start()
        await loadReservationsNow()
    }

    /// The load itself, for `connect()` and everything it reaches, which must not await `start()`: see there.
    func loadReservationsNow() async {
        guard let client, !unreachable else { return }
        await run("予約一覧を取得中") { self.reservations = try await client.reservations() }
    }

    /// What pulling the reservations down asks for: the list read again and what waits sent, or a connect when
    /// the app is not connected, which does both once the recorder has answered. Not connected, rather than
    /// offline: a recorder that answered the last connect without saying which it is, busy with somebody else
    /// as it was asked, is not offline, and the queue does not go to one (`flushPending`).
    func refreshReservations() async {
        if !connected {
            await connect()
        } else {
            await loadReservations()
            await flushPending()
        }
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

    /// Reservations that would clash. This asks the recorder with the very payload a creation would send, so
    /// it also proves the payload is one the recorder accepts, without recording anything.
    func conflicts(for program: GuideProgramRow, quality: String, repeating: String) async -> [Reservation]? {
        await start()
        guard let client, !unreachable,
              let request = ReservationRequest(program: program, quality: quality, repeating: repeating)
        else { return nil }
        // Opening a programme is the moment to find out whether the recorder is still up, and to wake it if
        // not, so that the reservation which usually follows goes straight through.
        guard await wakeIfDozing() else { return nil }
        do {
            return try await client.conflicts(elements: XsrsElements.create(request))
        } catch {
            // As for a recording's details (`detail(of:)`): what a client the model no longer holds ran into
            // is not about the recorder in play, and is neither taken for its silence nor put on its screens.
            guard client === self.client else { return nil }
            let deviceError = error as? any DeviceError
            if deviceError?.failure == .silent { lostTheRecorder() }
            problem = deviceError?.explanation ?? String(describing: error)
            return nil
        }
    }

    /// Writes to the recorder: after this the box really will record the programme.
    ///
    /// A reservation that cannot be delivered is queued and sent the next time the recorder answers. Only
    /// silence is queued — a recorder that answers and refuses has said something the reader needs to see — and
    /// only silence before anything was sent: one that went out and met silence may have been made all the
    /// same, and the queue would make it a second time.
    func reserve(_ program: GuideProgramRow, quality: String, repeating: String) async -> Bool {
        await start()
        guard let request = ReservationRequest(program: program, quality: quality, repeating: repeating) else {
            return false
        }
        // Known to be away: queue it now rather than spend a timeout finding out again.
        guard let client, !offline else {
            return await queue(request, serviceName: program.serviceName)
        }
        let activity = activities.begin("予約を登録中")
        defer { activities.end(activity) }
        // A recorder quiet for a while is made sure of first, and woken if it is asleep. When it cannot be,
        // nothing has been sent, so the queue is the place for this -- unless the check heard another recorder
        // and let go of this one: queued, the reservation would be held as one made for the recorder before.
        guard await wakeIfDozing() else {
            guard client === self.client else { return false }
            return await queue(request, serviceName: program.serviceName)
        }
        do {
            try await client.create(request)
            problem = nil
            await loadReservations()
            return true
        } catch let error as any DeviceError where error.failure == .silent {
            lostTheRecorder()
            problem = "予約の登録中にレコーダーの応答がなくなりました。届いている場合もあるため、送信待ちにはしていません。"
                + "再接続してから予約一覧で確かめてください。"
            return false
        } catch let error as any DeviceError {
            problem = error.explanation
            return false
        } catch {
            problem = String(describing: error)
            return false
        }
    }

    // MARK: - reservations waiting for the recorder

    /// Keeps a reservation the recorder never heard, and says so on screen rather than failing. Returns whether
    /// it was kept: one that could not be saved has been made nowhere.
    private func queue(_ request: ReservationRequest, serviceName: String) async -> Bool {
        guard let store else {
            problem = "予約を端末に保存できませんでした（端末内のデータベースを開けませんでした）"
            return false
        }
        let waiting = PendingReservation(request: request, serviceName: serviceName)
        do {
            try await store.queue(waiting)
            pending = try await store.pendingReservations()
            problem = nil
            queued = waiting
        } catch {
            problem = "予約を端末に保存できませんでした: \(error)"
            return false
        }
        // The reader learns that this was finally sent through a notification, so a queued reservation is where
        // the system's dialog belongs. After the reservation is saved, not before: the dialog waits on the
        // reader, who may leave the app instead of answering, and the reservation must not wait with it.
        await askForNotifications()
        return true
    }

    func loadPending() async {
        guard let store else { return }
        pending = (try? await store.pendingReservations()) ?? []
    }

    func removePending(_ waiting: PendingReservation) async {
        guard let store else { return }
        try? await store.removePending(waiting.id)
        await loadPending()
    }

    /// Sends one the recorder refused once more, because the reader has asked. A refused reservation is not
    /// sent again by itself (`PendingQueue.flush`), but the reason can go away -- a channel subscribed to
    /// since, an antenna put right -- and only the reader knows when it has. Sent now when the app is
    /// connected, and otherwise with the rest the next time the recorder answers.
    ///
    /// A row waiting for the television is its host's to send again, handed over first as a change or a
    /// delete of a television's reservation is (`update`): nothing below is for it. The recorder is not made
    /// sure of on its account, and it takes no turn in the recorder's sending. With no television in play
    /// nothing is done, and the row keeps its reason.
    func resend(_ waiting: PendingReservation) async {
        if waiting.target == .tv {
            await tvHost?.resend(waiting)
            return
        }
        await start()
        guard let store else { return }
        try? await store.setPendingProblem(waiting.id, nil)
        await loadPending()
        guard !offline, await wakeIfDozing() else { return }
        // There, and not connected: a recorder that answered the last connect without saying which it is. The
        // queue does not go to one (`flushPending`), so a connect asks it again, and sends the queue if it
        // describes itself.
        guard connected else {
            await connect()
            return
        }
        await flushPending()
    }

    /// Sends what has been waiting, by the rules in `PendingQueue` -- the same ones the overnight run uses.
    /// Called whenever the recorder has just answered, which means from inside `connect()`: nothing here may
    /// await `start()`.
    ///
    /// Only to a recorder that has described itself: whatever answers a connect some other way -- a 503, or as
    /// something that is no recorder -- must not be handed what was waiting for the last recorder.
    ///
    /// And only when a row waits for the recorder. What waits for the television is its own host's to send
    /// (`TVHost.sendWhatWaits`): with nothing but such rows the recorder's line would go up for a flush that
    /// sends nothing, and that flush would wait its turn behind a television's sending that is out.
    @discardableResult
    func flushPending() async -> Int {
        guard let client, let store, connected else { return 0 }
        await loadPending()
        guard pending.contains(where: { $0.target == .recorder }), !unreachable else { return 0 }
        let activity = activities.begin("送信待ちの予約を登録中")
        let outcome = await PendingQueue.flush(client: client, store: store)
        activities.end(activity)
        // What had not been sent stays queued for the next answer, and the app goes offline as it does for
        // any silence.
        if outcome.interrupted { lostTheRecorder() }
        await loadPending()
        if !outcome.sent.isEmpty { await loadReservationsNow() }
        // Said on screen, since a notification does not show while the app is in front (nothing here answers
        // `willPresent`). A flush with nothing to say -- everything waiting had been refused before -- leaves
        // the last line where it was. What is held for another recorder is said each time, for as long as any
        // is, and first: counted from the rows, since the attach that held them need not have got this far.
        // What became of the queue says which device it went to once a television is saved beside the
        // recorder, and not before (`PendingQueue.Outcome.said`).
        let held = pending.filter { $0.problem == Self.heldForAnotherRecorder }.count
        let heldBack = held == 0 ? nil
            : "別のレコーダーに切り替わったため、送信待ちの予約 \(held) 件は送らずに残しています。予約タブから送り直せます"
        let lines = [heldBack, outcome.said(withATelevisionSaved: tv != nil)].compactMap { $0 }
        if !lines.isEmpty { flushReport = lines.joined(separator: "。") }
        return outcome.sent.count
    }

    /// Changes the quality or the repeat of a reservation the recorder already holds, found again in a list
    /// read afresh, as for a deletion (`cancel`). The request keeps everything else, including the programme
    /// id, so a reservation that follows its programme goes on following it.
    ///
    /// A television's reservation is its host's to change, and is handed over before anything else: nothing
    /// below is for it, whatever state the recorder is in. Looked for in the recorder's list it would not be
    /// found -- a row of another device is no match there (`current`) -- so the recorder's branch could only
    /// say that the reservation had been deleted: this routing is what sends it to the television. With no
    /// television in play nothing is sent.
    func update(_ reservation: Reservation, quality: String, repeating: String) async -> Bool {
        if reservation.device == .tv {
            return await tvHost?.update(reservation, quality: quality, repeating: repeating) ?? false
        }
        await start()
        guard client != nil else { return false }
        // Sending would only wait out a timeout, from a list that could not be read again first.
        guard !offline else {
            problem = notConnected
            return false
        }
        // The read makes sure of the recorder too, and wakes it if it has gone to sleep.
        await loadReservations()
        guard !offline else { return false }   // the load has said why
        guard let target = reservations.current(reservation) else {
            problem = "この予約はすでにレコーダーから削除されていました。一覧を更新しました。"
            return false
        }
        guard let client,
              let request = ReservationRequest(changing: target, quality: quality, repeating: repeating)
        else { return false }
        let activity = activities.begin("予約を変更中")
        defer { activities.end(activity) }
        do {
            try await client.updateReservation(id: target.id, request)
        } catch let error as any DeviceError where error.failure == .silent {
            lostTheRecorder()
            problem = Self.mayHaveArrived
            return false
        } catch let error as any DeviceError where error.failure == .unknownItem {
            await loadReservations()
            problem = "レコーダー側で予約が更新されていました。一覧を更新したので、もう一度お試しください。"
            return false
        } catch {
            problem = (error as? any DeviceError)?.explanation ?? String(describing: error)
            return false
        }
        problem = nil
        await loadReservations()
        return true
    }

    /// Deletes one reservation, as the recorder holds it now rather than by the id the app happens to hold.
    ///
    /// The recorder rewrites the ids of the reservations its own automatic recording made, the whole block of
    /// them at once, when it works through the guide again (`Reservation.createdByRecorder`): an id read a few
    /// hours ago can be dead while the row still looks right, and deleting it answers 804. So the list is read
    /// again first and this reservation found in it: by its id while that stands, and otherwise by its channel
    /// and the moment it starts (`current`).
    ///
    /// Also a write. A recorder that refuses says why, and the reason is left on screen, not reloaded away.
    ///
    /// A television's reservation is its host's to delete, handed over first as for a change (`update`).
    @discardableResult
    func cancel(_ reservation: Reservation) async -> Bool {
        if reservation.device == .tv { return await tvHost?.cancel(reservation) ?? false }
        await start()
        guard client != nil else { return false }
        // as for a change: the list has to be read first, and nothing can be read
        guard !offline else {
            problem = notConnected
            return false
        }
        await loadReservations()
        guard !offline else { return false }
        guard let target = reservations.current(reservation) else {
            problem = "この予約はすでにレコーダーから削除されていました。一覧を更新しました。"
            return false
        }
        guard let client else { return false }
        let activity = activities.begin("予約を削除中")
        do {
            try await client.deleteReservation(id: target.id)
        } catch let error as any DeviceError where error.failure == .silent {
            activities.end(activity)
            lostTheRecorder()
            problem = Self.mayHaveArrived
            return false
        } catch let error as any DeviceError where error.failure == .unknownItem {
            // the list we just read was itself out of date, which is what happens when reading it failed
            activities.end(activity)
            await loadReservations()  // first, because a successful read clears `problem`
            problem = "レコーダー側で予約が更新されていました。一覧を更新したので、もう一度お試しください。"
            return false
        } catch {
            activities.end(activity)
            problem = (error as? any DeviceError)?.explanation ?? String(describing: error)
            return false
        }
        activities.end(activity)
        problem = nil
        reservations.removeAll { $0.id == target.id }
        await loadReservations()
        // the reload asks the recorder again, and if it is a moment behind itself the row would come back
        reservations.removeAll { $0.id == target.id }
        return true
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
