import Foundation
import Observation
import RecorderKit

/// The reservations' screen as the reader works it: the delete a row's swipe asks for and its question, a waiting
/// row sent again and what that came to, what the one alert says, and what the screen says over its list. The
/// screen lays it out and hands this what is swiped and pressed; the lists themselves, how they are sorted and
/// which kind is shown are the model's (`reservationSections`, `reservationSort`, `reservationKind`).
@MainActor
@Observable
public final class ReservationsState {
    @ObservationIgnored private let model: AppModel

    /// The row swiped, by its key in the list rather than by value: the reservation itself is read back out of the
    /// model when the question asks, so a delete can only ever be sent for a row the list still holds. By its key
    /// and not its id, which each device numbers for itself: a television's row is found by no id among the
    /// recorder's, and an id the two share would find the recorder's row for the television's. The device that
    /// holds it is kept with the key: the row is let go of when that device's lists are, and not when the other's
    /// are.
    private var removing: Picked?
    /// The same for a reservation waiting to be sent, read back out of the queue.
    private var removingPending: String?
    private var failure: String?
    /// What a waiting reservation sent again came to, where its row does not say it, or what a sending made of one
    /// the reader was deleting: said once, in the alert.
    private var said: String?

    private struct Picked {
        var listKey: String
        var device: DeviceSlot
    }

    public init(model: AppModel) {
        self.model = model
    }

    // MARK: - the question or the answer

    /// One alert does every job, because two on the same view is not something SwiftUI promises to honour.
    public enum Ask {
        case confirm(Reservation)
        case confirmPending(PendingReservation)
        case failed(String)
        case said(String)
    }

    /// What the alert is up for. A failure wins: it is the answer to what was just asked. So is what a waiting
    /// reservation sent again came to.
    public var ask: Ask? {
        if let failure { return .failed(failure) }
        if let said { return .said(said) }
        if let removing, let reservation = model.reservation(listKey: removing.listKey) {
            return .confirm(reservation)
        }
        if let id = removingPending, let waiting = model.pending.first(where: { $0.id == id }) {
            return .confirmPending(waiting)
        }
        return nil
    }

    public var askTitle: String {
        switch ask {
        case .failed: "エラー"
        case .said: "送信待ちの予約"
        case .confirmPending: "送信待ちの予約を削除しますか？"
        case .confirm, nil: "この予約を削除しますか？"
        }
    }

    /// What the question or the answer says under its title.
    public func message(for asked: Ask) -> String {
        switch asked {
        case .confirm(let reservation):
            "\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
                + reservation.whatDeletingDoes(fromTheList: true)
        case .confirmPending(let waiting):
            "\(Format.dateTime.string(from: waiting.request.start)) \(waiting.request.title)\n"
                + waiting.whatDeletingDoes
        case .failed(let reason), .said(let reason):
            reason.asABody
        }
    }

    /// The button that does something, beside the one that closes: nil where there is none.
    public func actionLabel(for asked: Ask) -> (label: String, destructive: Bool)? {
        switch asked {
        case .confirm, .confirmPending: ("削除する", true)
        case .failed, .said: nil
        }
    }

    /// The button that closes: OK for what only says, キャンセル for a question.
    public func closingLabel(for asked: Ask) -> String {
        switch asked {
        case .confirm, .confirmPending: "キャンセル"
        case .failed, .said: "OK"
        }
    }

    /// 削除する, under the question: of the row the question was asked about, as it was handed to the button. What
    /// it came to is said in the same alert, once the question has closed -- why a reservation was not deleted, or
    /// that a sending made the waiting row first.
    public func act(on asked: Ask) {
        switch asked {
        case .confirm(let reservation):
            Task {
                if case .notDone(let why) = await model.cancel(reservation) { failure = why }
            }
        case .confirmPending(let waiting):
            Task { if let instead = await model.deleteWaiting(waiting) { said = instead } }
        case .failed, .said:
            break
        }
    }

    /// Lets go of whatever the alert was up for, as it closes.
    public func askClosed() {
        (removing, removingPending, failure, said) = (nil, nil, nil, nil)
    }

    // MARK: - a row swiped

    /// 削除 on a reservation's row: asked first.
    public func delete(_ reservation: Reservation) {
        removing = Picked(listKey: reservation.listKey, device: reservation.device)
    }

    /// A row stays listed until its delete has read the list again, the recorder's as a television's, and a second
    /// delete sent meanwhile would be answered as if the first had failed: held while the row's own device works.
    public func holdsDeleting(_ reservation: Reservation) -> Bool { model.isBusy(for: reservation.device) }

    /// 削除 on a waiting row, as on the reservations below it, and asked first like every other delete.
    public func deleteWaiting(_ waiting: PendingReservation) {
        removingPending = waiting.id
    }

    /// A waiting row is held back while the device it waits for works, as that device's reservations are: a sending
    /// that is out may have this row in hand. Never by the other device's work.
    public func holds(_ waiting: PendingReservation) -> Bool { model.isBusy(for: waiting.target) }

    /// もう一度送る is offered on a row a device refused. A refused one is not sent again by itself, since the answer
    /// would be the same; the reader is the one who knows when whatever it names has changed.
    public func offersSendingAgain(_ waiting: PendingReservation) -> Bool { waiting.problem != nil }

    /// もう一度送る. What it came to is said in the alert where the row does not say it, whichever device it waits
    /// for; what the sending sent is said on the strip as well. Nothing to say is not kept: it would take down what
    /// another row's sending put up meanwhile -- a recorder's can be out for as long as a waking takes, and a
    /// television's row sent after it is answered first -- before it was read.
    public func sendAgain(_ waiting: PendingReservation) {
        Task {
            if let more = await model.sendAgain(waiting)?.besideItsRow { said = more }
        }
    }

    /// The reservation picked for deletion is the last recorder's when its lists are let go of (`timesForgotten`).
    /// Not a waiting reservation picked for deletion, which is the reader's and no recorder's.
    public func recordersListsLetGo() {
        if removing?.device == .recorder { removing = nil }
    }

    /// A television's row goes the same way with the television's lists (`tvTimesForgotten`), and neither device's
    /// going lets go of a row of the other's.
    public func televisionsListsLetGo() {
        if removing?.device == .tv { removing = nil }
    }

    // MARK: - what the screen says

    /// Under the screen's title: the kind shown when it is not all of them, how many, and how many of those are
    /// recording now or clash.
    public var subtitle: String {
        let shown = model.shownReservations
        let recording = shown.filter(\.recording).count
        let clashing = shown.filter(\.conflict).count
        var parts: [String] = []
        if model.reservationKind != .all { parts.append(model.reservationKind.label) }
        parts.append("\(shown.count) 件")
        if recording > 0 { parts.append("録画中 \(recording)") }
        if clashing > 0 { parts.append("重複 \(clashing)") }
        return parts.joined(separator: " · ")
    }

    /// Whether the list is narrowed to a kind or sorted otherwise than by time, which the menu's icon marks.
    public var narrowedOrSorted: Bool { !(model.reservationSort == .time && model.reservationKind == .all) }

    /// A device whose list on screen is old, and since when.
    public struct Stale: Identifiable, Sendable {
        public var device: DeviceSlot
        public var since: Date
        public var id: DeviceSlot { device }
    }

    /// A device that cannot be asked leaves its last list up, and what is on screen says how old that is -- above
    /// its rows only, so not while the kind shown leaves them out. The recorder's first.
    public var stale: [Stale] {
        [DeviceSlot.recorder, .tv].compactMap { device in
            guard let since = model.staleSince(for: device),
                  model.shownReservations.contains(where: { $0.device == device }) else { return nil }
            return Stale(device: device, since: since)
        }
    }

    /// What is said of such a list at `now`, which the screen moves on once a minute. The words never say less than
    /// one minute: a count of seconds would stand still until the next turn.
    public func staleLine(_ stale: Stale, at now: Date) -> String {
        let read = Self.ago(min(stale.since, now.addingTimeInterval(-60)))
        return "\(stale.device.label)の予約は\(read)に読んだものです"
    }

    /// How long ago, in numbers and in Japanese (5 分前, and hours and days as they come): the words are part of a
    /// Japanese sentence wherever the phone is set to, and 昨日 for a list read a day ago would say less than the
    /// count does.
    private static func ago(_ date: Date) -> String {
        date.formatted(.relative(presentation: .numeric).locale(Locale(identifier: "ja_JP")))
    }
}
