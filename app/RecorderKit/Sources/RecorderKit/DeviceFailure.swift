import Foundation

/// What went wrong, in the terms the rules care about, whichever device said it.
///
/// The queue, the waking loop and the guide refresh do not read an error for what it is but for what to do
/// about it: wake the device, try again later, hold the request back, tell the reader. Those are the same
/// questions for a recorder answering SOAP faults and for a television answering JSON error codes, so each
/// device's own error says which of these it is (`DeviceError.failure`) and the rules read only that.
public enum DeviceFailure: Sendable, Equatable {
    /// Nothing answered at all. The one failure worth waking a device for, and the one that makes the app give
    /// up on it until the network changes or the reader asks.
    case silent
    /// The device is there and busy with somebody else's request. It said nothing about this one: ask later.
    case busy
    /// The device turned this request down for a reason of its own. Asking again gets the same answer, so a
    /// reservation waiting in the queue keeps the reason and is not sent again until the reader says so.
    case refused(reason: String)
    /// The device cannot do it as it stands -- nowhere to record to, no room for another reservation -- which
    /// is about the device rather than the request: every request would get the same answer.
    case deviceCannot(reason: String)
    /// The device wants the app registered with it first. It is there and answering, so not `silent`.
    case needsPairing
    /// The device has to be switched on before this will work.
    case needsPower
    /// The device has no such reservation or recording: the list the app holds is stale.
    case unknownItem
    /// The device already holds what it was asked to make.
    case alreadyThere
    /// The saved address is not something a request can be sent to, so nothing was.
    case badAddress
    /// An answer, but not one that says anything about the request: no code in it, the wrong shape, a file
    /// the device has not built. Passing, as far as anybody can tell.
    case unexpected(String)

    /// True when the device answered about the request itself and the answer will not change by asking again.
    /// What the queue holds a reservation back for, with the reason written on it.
    public var turnsTheRequestDown: Bool {
        switch self {
        case .refused, .unknownItem: true
        default: false
        }
    }
}

/// An error from a device, of whichever kind, that can say which `DeviceFailure` it is.
public protocol DeviceError: Error, Sendable {
    var failure: DeviceFailure { get }
    /// What to put in front of the reader.
    var explanation: String { get }
}

extension RecorderError: DeviceError {
    /// The same reading as `unreachable`, `refusal`, `needsPowerOn` and `unknownReservation`, which stay as they
    /// are for the code that knows it is talking to a recorder. The order matters where two apply: 880 is
    /// standby whatever the status, and a 503 is the recorder busy whatever code came with it.
    public var failure: DeviceFailure {
        switch self {
        case .transport, .notHTTP: .silent
        case .busy: .busy
        case .badAddress: .badAddress
        case .soap(_, _, "880", _): .needsPower
        case .soap(_, 503, _, _): .busy
        case .soap(_, _, "804", _), .soap(_, _, "820", _): .unknownItem
        case .soap(_, _, .some, _): .refused(reason: explanation)
        case .soap, .badResponse, .unexpectedAnswer, .guideFileMissing, .notARecorder: .unexpected(explanation)
        }
    }
}
