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

/// Which of a household's devices something is for. A name of the app's own, written on what waits to be
/// sent, and never anything the hardware calls itself: the recorder that takes another's place is still the
/// recorder. A string underneath, so that one written by a version that knows more devices than this one is
/// read as what it is, and left alone.
public struct DeviceSlot: RawRepresentable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let recorder = DeviceSlot(rawValue: "recorder")
    /// The household's television. The spelling will be written on what waits for it, as the recorder's is,
    /// so it is not to change.
    public static let tv = DeviceSlot(rawValue: "tv")
}

/// A device the guide can be fetched from, a broadcasting type at a time.
public protocol GuideSource: DeviceEndpoint {
    /// The guide for one broadcasting type. Nil when the device has no such channels.
    func guide(_ broadcasting: String) async throws -> [GuideService]?
    /// The station logos for one broadcasting type. Nil when the device has no such channels.
    func logos(_ broadcasting: String) async throws -> [StationLogo]?
}

/// A device reservations are made on. Making one says nothing back worth keeping: what the device made is
/// read from its list afterwards, which is also the only way a television says it.
public protocol ReservationTarget: DeviceEndpoint {
    func create(_ request: ReservationRequest) async throws
}

extension RecorderClient: DeviceEndpoint {
    /// `description.xml`, which is one request and is bounded by `timeout` (see `describe`).
    public func probe(timeout: TimeInterval) async throws {
        try await describe(timeout: timeout)
    }
}

extension RecorderClient: GuideSource {}

extension RecorderClient: ReservationTarget {}
