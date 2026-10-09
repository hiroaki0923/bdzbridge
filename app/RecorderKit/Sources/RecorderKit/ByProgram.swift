import Foundation

/// Reservations, and rows that wait to be sent, by the programme each follows: its broadcasting type, its
/// service and its programme id, which is what tells one programme from another in the guide, in the devices'
/// lists and in the queue. A reservation made by its times carries no programme id, and is by none.
public enum ByProgram {
    /// A programme of the guide's, by its broadcasting's code; nil for a broadcasting the tables do not know.
    public static func key(_ program: GuideProgramRow) -> String? {
        Codes.broadcasting[program.broadcasting].map { key($0, program.serviceID, program.eventID) }
    }

    public static func key(_ broadcastingType: Int, _ serviceID: Int, _ eventID: Int) -> String {
        "\(broadcastingType)-\(serviceID)-\(eventID)"
    }

    /// Each programme's reservation, the first in the list where it holds more than one.
    public static func of(_ reservations: [Reservation]) -> [String: Reservation] {
        Dictionary(reservations.compactMap { reservation in
            reservation.eventID.map { (key(reservation.broadcastingType, reservation.serviceID, $0), reservation) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Each programme's row that waits, the first in the queue where it holds more than one.
    public static func of(_ pending: [PendingReservation]) -> [String: PendingReservation] {
        Dictionary(pending.compactMap { waiting in
            waiting.request.eventID.map {
                (key(waiting.request.broadcastingType, waiting.request.serviceID, $0), waiting)
            }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether `list`, read from a device, holds a reservation that answers for `waiting`: one of its
    /// programme. A row with no programme id is answered by none.
    public static func lists(_ waiting: PendingReservation, in list: [Reservation]) -> Bool {
        waiting.request.eventID.map {
            of(list)[key(waiting.request.broadcastingType, waiting.request.serviceID, $0)] != nil
        } ?? false
    }
}
