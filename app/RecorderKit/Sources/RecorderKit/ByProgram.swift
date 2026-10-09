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
    /// programme that is all the row asks for, as a television's round takes a reservation it lists for a
    /// row it need not send (`ScalarClient.openRound`). So not one whose repeat falls short of the row's
    /// (`Codes.repeating(_:fallsShortOf:)`): the programme recorded once, or a repeat on fewer of the days,
    /// where the row asks for a repeat -- taken for the row, the other days would go unreserved with nothing
    /// said. And not a reservation the recorder made for itself (`Reservation.createdByRecorder`): the
    /// recorder renumbers and decides those again whenever it works through the guide, and the row asks for
    /// a reservation of the reader's own. A television has none such. A row with no programme id is answered
    /// by none.
    public static func lists(_ waiting: PendingReservation, in list: [Reservation]) -> Bool {
        guard let programme = waiting.request.eventID else { return false }
        return list.contains { listed in
            listed.eventID == programme && listed.broadcastingType == waiting.request.broadcastingType
                && listed.serviceID == waiting.request.serviceID && !listed.createdByRecorder
                && !Codes.repeating(listed.repeatCode, fallsShortOf: waiting.request.repeatCode)
        }
    }
}
