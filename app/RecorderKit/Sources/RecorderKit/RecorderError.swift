import Foundation

public enum RecorderError: Error, Equatable, Sendable {
    /// The recorder rejected the request: HTTP status plus the UPnP `errorCode` from the SOAP fault.
    case soap(action: String, status: Int, code: String?, body: String)
    /// Something below HTTP went wrong: no route, refused connection, timeout.
    case transport(String)
    /// An answer that was not XML at all, usually a wrong path or a different device on that port.
    case badResponse(status: Int)
    /// A well-formed answer without what was asked for in it, or not in the shape the BDZ-FBT4100 gives it:
    /// most likely another model of the series, answering a call it shares in a way of its own. Not
    /// `unreachable`, since the recorder is there, and not a `refusal` either.
    case unexpectedAnswer(action: String)
    /// The recorder answered, but not with the guide file asked for. A BDZ-FBT4100 answers 500 here while
    /// it has no file to give: after the box is restarted or its channels are re-scanned, the files are
    /// gone until it builds them again, which it does in the small hours.
    case guideFileMissing(name: String, status: Int)
    case notHTTP
    /// The recorder was reached but is not the one we expect.
    case notARecorder(host: String)
    /// The saved address is not something a URL can be built on, so nothing was sent. Not `unreachable`:
    /// the recorder was never asked, and waking it would not make the address any better.
    case badAddress(host: String)

    /// What to put in front of the reader. Japanese, because this is the text the app shows; the code and
    /// the action stay in it so that a report of it can be looked up in docs/xsrs-api.md.
    public var explanation: String {
        switch self {
        case .soap(let action, let status, let code, _):
            switch code {
            case "402": "レコーダーがこの要求を受け付けませんでした (402: \(action))"
            case "804": "この予約はレコーダーにありません (804: \(action))"
            case "820": "この録画はレコーダーにありません (820: \(action))"
            case "831": "このチャンネルは受信できないため、番組を指定した予約はできません。"
                        + "契約状況やアンテナの設定を確認してください (831: \(action))"
            case "880": "レコーダーがスタンバイ状態です。先に電源を入れてください (880: \(action))"
            case .some(let code): "レコーダーがエラーを返しました (\(code): \(action), HTTP \(status))"
            case nil: "レコーダーが HTTP \(status) を返しました (\(action))"
            }
        case .transport: "レコーダーに接続できませんでした。電源とネットワーク接続を確認してください"
        case .badResponse(let status): "レコーダーから正しい応答がありませんでした (HTTP \(status))"
        case .unexpectedAnswer(let action): "レコーダーの応答を読み取れませんでした (\(action))"
        case .guideFileMissing(let name, let status):
            "レコーダーから番組表ファイルを取得できませんでした (HTTP \(status): \(name))。"
                + "レコーダーの再起動やチャンネルの再スキャンの直後は、番組表が作り直されるまで取得できません。"
        case .notHTTP: "レコーダーの応答を解釈できませんでした"
        case .notARecorder(let host): "\(host) はソニー製レコーダーとして応答しませんでした"
        case .badAddress(let host):
            "「\(host)」はレコーダーのアドレスとして使えません。"
                + "設定の「IP アドレス」に、192.168.1.10 のような形で入力し直してください。"
        }
    }

    /// The same thing with whatever the network layer said, for a log. `explanation` leaves it out: a
    /// URLSession error printed in full is several hundred characters of domains and codes, and putting that
    /// on screen tells the reader nothing and hides the sentence that does.
    public var detail: String {
        switch self {
        case .transport(let detail): "\(explanation) (\(detail))"
        case .soap(_, _, _, let body): "\(explanation) \(body.prefix(200))"
        default: explanation
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

    /// True when the recorder turned the request down for a reason of its own: a SOAP fault carrying a UPnP
    /// `errorCode`, such as 402 for a request it will not take or 831 for a channel it cannot receive. Asking
    /// again gets the same answer, so a reservation waiting in the queue is not sent again after one of these
    /// until the reader says so.
    ///
    /// Not a 503, which is the recorder busy with somebody else's request; not an answer with no code in it,
    /// which says nothing about the request; and not 880, which is about the recorder being in standby rather
    /// than about what was asked. Those pass, and asking again later is right.
    public var refusal: Bool {
        guard case .soap(_, let status, let code?, _) = self else { return false }
        return status != 503 && code != "880"
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

public extension RecorderError {
    /// Runs a read the app can do without -- the firmware version and the free space, which are only shown,
    /// and the MAC, which is only kept for later -- and lets nothing out of it but silence.
    ///
    /// Every call this package makes is answered by a BDZ-FBT4100, but the rest of the series need not answer
    /// all of them, or answer them in the same shape. A recorder that refuses a read like this one, or gives
    /// an answer that cannot be read, is a recorder that is there, and the value is merely not known: nil,
    /// for the caller to carry on without. Failing on it made the whole connection fail over a line in the
    /// settings. Silence is thrown all the same, since it says the recorder is not there, whatever was asked.
    ///
    /// The read runs on the caller's actor, as if it had been written out in place.
    static func silenceOnly<T>(isolation: isolated (any Actor)? = #isolation,
                               _ read: () async throws -> T) async throws -> T? {
        do {
            return try await read()
        } catch let error as RecorderError where error.unreachable {
            throw error
        } catch {
            return nil
        }
    }
}
