import Foundation

/// Something on the LAN that requests are sent to: the recorder, and whatever else the app comes to talk to.
///
/// The rules the screens and the overnight run share -- waiting for a device to wake, sending what waits in
/// the queue, fetching the guide -- are written against these protocols and not against `RecorderClient`, so
/// that a device of another kind can be put behind them. Each protocol holds only what one of those rules
/// asks for; what only the recorder's own screens use stays on `RecorderClient`.
public protocol DeviceEndpoint: Actor {
    /// The short ask that shows the device is listening, and nothing more: who it is, not everything about
    /// it. Throws when it does not answer, or answers as something else.
    func probe(timeout: TimeInterval) async throws
}

/// A device the guide can be fetched from, a broadcasting type at a time.
public protocol GuideSource: DeviceEndpoint {
    /// The guide for one broadcasting type. Nil when the device has no such channels.
    func guide(_ broadcasting: String) async throws -> [GuideService]?
    /// The station logos for one broadcasting type. Nil when the device has no such channels.
    func logos(_ broadcasting: String) async throws -> [StationLogo]?
}

/// What a device says when it has made a reservation.
public enum ReservationReceipt: Sendable, Equatable {
    /// The id the device gave the reservation.
    case id(String)
    /// The device made it and did not say what it called it: it is found in the device's list, by its
    /// channel and its start.
    case lookUpByChannelAndStart
}

/// A device reservations are made on.
public protocol ReservationTarget: DeviceEndpoint {
    func create(_ request: ReservationRequest) async throws -> ReservationReceipt
}

extension RecorderClient: DeviceEndpoint {
    /// `description.xml`, which is one request and is bounded by `timeout` (see `describe`).
    public func probe(timeout: TimeInterval) async throws {
        try await describe(timeout: timeout)
    }
}

extension RecorderClient: GuideSource {}

extension RecorderClient: ReservationTarget {
    /// The protocol's way in, for the rules that take any device. Code that knows it has a recorder and wants
    /// the id calls `createReservation`, which this is.
    public func create(_ request: ReservationRequest) async throws -> ReservationReceipt {
        .id(try await createReservation(request))
    }
}
