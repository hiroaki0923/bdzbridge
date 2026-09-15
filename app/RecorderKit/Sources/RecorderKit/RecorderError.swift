import Foundation

public enum RecorderError: Error, Equatable, Sendable {
    /// The recorder rejected the request: HTTP status plus the UPnP `errorCode` from the SOAP fault.
    case soap(action: String, status: Int, code: String?, body: String)
    /// Something below HTTP went wrong: no route, refused connection, timeout.
    case transport(String)
    /// An answer that was not XML at all, usually a wrong path or a different device on that port.
    case badResponse(status: Int)
    /// The recorder answered, but not with the guide file asked for. A BDZ-FBT4100 answers 500 here while
    /// it has no file to give: after the box is restarted or its channels are re-scanned, the files are
    /// gone until it builds them again, which it does in the small hours.
    case guideFileMissing(name: String, status: Int)
    case notHTTP
    /// The recorder was reached but is not the one we expect.
    case notARecorder(host: String)

    /// What to put in front of the reader. Japanese, because this is the text the app shows; the code and
    /// the action stay in it so that a report of it can be looked up in docs/xsrs-api.md.
    public var explanation: String {
        switch self {
        case .soap(let action, let status, let code, _):
            switch code {
            case "402": "レコーダーがこの要求を受け付けませんでした (402: \(action))"
            case "804": "レコーダーにこの予約がありません (804: \(action))"
            case "820": "レコーダーにこの録画がありません (820: \(action))"
            case "831": "このチャンネルは受信できないため、番組を選んだ予約ができません。"
                        + "契約やアンテナの設定を確かめてください (831: \(action))"
            case "880": "レコーダーが待機状態です。先に電源を入れてください (880: \(action))"
            case .some(let code): "レコーダーがエラーを返しました (\(code): \(action), HTTP \(status))"
            case nil: "レコーダーが HTTP \(status) を返しました (\(action))"
            }
        case .transport(let detail): "レコーダーに届きませんでした: \(detail)"
        case .badResponse(let status): "レコーダーの応答が XML ではありませんでした (HTTP \(status))"
        case .guideFileMissing(let name, let status):
            "レコーダーが番組表のファイルを渡してくれませんでした (HTTP \(status): \(name))。"
                + "本体を再起動したりチャンネルを再スキャンした直後は、レコーダーが作り直すまでこうなります。"
        case .notHTTP: "レコーダーの応答が HTTP ではありませんでした"
        case .notARecorder(let host): "\(host) はソニーのレコーダーだと名乗りませんでした"
        }
    }

    /// True when nothing answered at all, as opposed to a recorder that answered with an error. That is
    /// the case worth acting on by itself: a BDZ-FBT4100 leaves the LAN when it has been idle a while, and
    /// a magic packet is the only thing that reaches it there.
    public var unreachable: Bool {
        switch self {
        case .transport, .notHTTP: true
        default: false
        }
    }

    /// True when the recorder needs powering on before this will work.
    public var needsPowerOn: Bool {
        if case .soap(_, _, "880", _) = self { return true }
        return false
    }

    /// True when the recorder says it has no such reservation. It is worth telling apart: the reservation
    /// the app is holding has gone, which is a stale list rather than a failed delete.
    public var unknownReservation: Bool {
        if case .soap(_, _, "804", _) = self { return true }
        return false
    }

    /// True when the recorder refuses to follow a programme because it cannot receive the channel. Verified
    /// on a BDZ-FBT4100: creating a reservation with a `desiredMatchingID` answers 831 on a pay channel the
    /// box is not subscribed to, while the same request without one is accepted. Recording it by time would
    /// only capture a scrambled stream, so there is nothing useful to offer instead.
    public var unreceivableChannel: Bool {
        if case .soap(_, _, "831", _) = self { return true }
        return false
    }
}
