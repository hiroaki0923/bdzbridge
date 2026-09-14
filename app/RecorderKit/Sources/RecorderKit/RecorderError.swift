import Foundation

public enum RecorderError: Error, Equatable, Sendable {
    /// The recorder rejected the request: HTTP status plus the UPnP `errorCode` from the SOAP fault.
    case soap(action: String, status: Int, code: String?, body: String)
    /// Something below HTTP went wrong: no route, refused connection, timeout.
    case transport(String)
    /// An answer that was not XML at all, usually a wrong path or a different device on that port.
    case badResponse(status: Int)
    case notHTTP
    /// The recorder was reached but is not the one we expect.
    case notARecorder(host: String)

    /// Codes seen on a BDZ-FBT4100. See docs/xsrs-api.md.
    public var explanation: String {
        switch self {
        case .soap(let action, let status, let code, _):
            switch code {
            case "402": "\(action): the request shape was rejected (402)"
            case "820": "\(action): no such recording on the recorder (820)"
            case "880": "\(action): the recorder is in network standby and has to be powered on first (880)"
            case .some(let code): "\(action): the recorder answered UPnP error \(code) (HTTP \(status))"
            case nil: "\(action): the recorder answered HTTP \(status)"
            }
        case .transport(let detail): "could not reach the recorder: \(detail)"
        case .badResponse(let status): "the answer was not XML (HTTP \(status))"
        case .notHTTP: "the answer was not an HTTP response"
        case .notARecorder(let host): "\(host) did not describe itself as a Sony recorder"
        }
    }

    /// True when the recorder needs powering on before this will work.
    public var needsPowerOn: Bool {
        if case .soap(_, _, "880", _) = self { return true }
        return false
    }
}
