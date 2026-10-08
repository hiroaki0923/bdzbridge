import Foundation

/// Passes a search's requests on to the transport it is given and counts how each came back, for the search's
/// line in the log (`ScanLog`): answered, by status; timed out; failed in transit, by the system's code. To the
/// search itself every one of those but a 200 is an address where no recorder lives (`Discovery.probe`), and
/// which of them it was is the one thing that tells a subnet with nobody on it from a phone that let nothing
/// out: a search reads that off the counts too (`Counts.mostTurnedAway`).
///
/// Beside the counts it keeps one address: the first whose request the system turned away (`turnedAwayAt`),
/// for a search whose look was turned away to ask again. It is kept in memory for as long as the tally,
/// which a search makes for one look, and it is in neither the counts nor their summary, so nothing of it
/// reaches the log. No other address is kept, and nothing of what was answered.
public actor ScanTally: HTTPTransport {
    public struct Counts: Sendable, Equatable {
        /// Requests that were answered, by HTTP status.
        public var answered: [Int: Int] = [:]
        /// Requests the system gave up on when their time ran out (`NSURLErrorTimedOut`).
        public var timedOut = 0
        /// Requests that failed in transit any other way, by the system's code for it: -1009 where it had no
        /// network to send on, -1004 where the address refused the connection, -999 where the request was
        /// cancelled, as the search does to one that has outlived its time.
        public var failed: [Int: Int] = [:]
        /// Failures with no code of the system's to go by.
        public var other = 0

        public init() {}

        public var asked: Int {
            answered.values.reduce(0, +) + timedOut + failed.values.reduce(0, +) + other
        }

        /// Whether the system turned away most of the requests counted here: those it turned away outnumber
        /// all the rest together, answered ones included. A search reads its look through a subnet so, and the
        /// one request it sends again to an address that look saw turned away (`Discovery.turnedAway`), of
        /// which most is all.
        ///
        /// The system turned a request away when it failed with a code of the system's that is none of the
        /// ways a request that was out comes back (`turnedAway(_:)`). An answer, whatever its status. A timeout
        /// (-1001), which is how an address where nobody lives comes back: a search gives each a little over a
        /// second. A cancellation (-999), which is how the same silence comes back when the request has
        /// outlived that time and the search has ended it (`Discovery.probe` races each against a deadline of
        /// its own, since one was seen not to end on an iPhone). A connection an address refused (-1004) or
        /// dropped (-1005). A failure with no code of the system's says nothing of the system either.
        ///
        /// By most, and not by every request, because some addresses are let through without the permission:
        /// "If your device's DNS server is on a local network, traffic to it doesn't require local network
        /// access." and "If your device uses a network proxy and that proxy is on a local network, traffic to
        /// it doesn't require local network access." (Apple's TN3179). Such an address comes back as it would
        /// with the permission given while every other request is turned away. On one phone, on 2026-10-06, a
        /// look made behind the system's question came back with 252 requests failed -1009 and one -1004. One
        /// that drops the port where that one refused it comes back as a timeout, and a home may have both.
        /// With the permission given, "the system allows the operation" (the technote), and none of the looks
        /// that phone made with it came back with a request turned away. So a subnet where every address
        /// refused at once is not turned away, nor a look most of whose requests were out and a few turned
        /// away.
        ///
        /// Read off the ways of having been out, and not off the code a request turned away carries. The one
        /// seen is -1009, on that phone, and the one to expect: a session that does not wait for connectivity
        /// "fails immediately with an error, such as NSURLErrorNotConnectedToInternet" (Apple,
        /// `URLSessionConfiguration.waitsForConnectivity`), and "such as" names no list.
        ///
        /// What this cannot tell: requests the system held and then let time out. Those count as timeouts,
        /// and a look made of them is a subnet with nobody on it. Nor a request that failed at once for another
        /// reason than the permission: the same page gives "the device might require a VPN connection but none
        /// is available", and a look made where that is so reads as turned away with the permission given.
        /// Neither has been seen.
        public var mostTurnedAway: Bool {
            let turnedAway = failed.reduce(0) { Self.turnedAway($1.key) ? $0 + $1.value : $0 }
            return turnedAway > asked - turnedAway
        }

        /// The system's codes for a failure that says the request was out for its time: timed out, should one
        /// be counted by its code; cancelled.
        private static let codesOfARequestThatWasOut = [-1001, -999]

        /// The system's codes for a request an address turned down: refused; dropped.
        private static let codesOfAnAddressThatTurnedItDown = [-1004, -1005]

        /// Whether a failure with this code of the system's is the system turning the request away: none of
        /// the ways a request that was out, or that an address turned down, comes back.
        static func turnedAway(_ code: Int) -> Bool {
            !(codesOfARequestThatWasOut + codesOfAnAddressThatTurnedItDown).contains(code)
        }

        /// The statuses the requests counted here were answered with and the system's codes they failed with,
        /// each once and in order, a timeout's -1001 among them, and "no code" for a failure with none. For a
        /// line in the log about one request, of which the summary's heads would say little more than that.
        public var statusesAndCodes: String {
            var numbers = Set(answered.keys).union(failed.keys)
            if timedOut > 0 { numbers.insert(ScanTally.timedOut) }
            return (numbers.sorted().map(String.init) + (other > 0 ? ["no code"] : [])).joined(separator: ", ")
        }

        /// The counts in one line, the statuses and the codes in order.
        public var summary: String {
            func byNumber(_ counts: [Int: Int]) -> String {
                counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            }
            return "asked \(asked); answered [\(byNumber(answered))]; timed out \(timedOut); "
                + "failed [\(byNumber(failed))]; other \(other)"
        }
    }

    private let transport: any HTTPTransport
    public private(set) var counts = Counts()

    /// The address of the first request the system turned away (`Counts.turnedAway`), or nil while none has
    /// been. Not one refused or dropped: that came from an address, which may be one the system lets through
    /// unasked. Not one that failed with no code of the system's: nothing says the system turned it away.
    ///
    /// Nor, for a tally told a port (`keepingAddressFrom`), one of a request at another port. The address the
    /// system lets through unasked is asked there too by a search that asks more than one kind of request,
    /// and may fail there with a code read as turned away -- an answer the session cannot read, say -- where at
    /// the port it is asked again at it refuses or is silent. Kept, it would be asked again, and read as let
    /// out while the permission was never given.
    public private(set) var turnedAwayAt: String?
    /// The port whose turned-away requests may give `turnedAwayAt`; nil, any.
    private let keptFrom: Int?

    /// `port`: the port whose turned-away requests may give `turnedAwayAt`; nil, any. A search that asks more
    /// than one kind of request names the kind it asks again (`Discovery.turnedAway`'s, `Upnp.port`). The
    /// counts are every request's either way.
    public init(_ transport: any HTTPTransport, keepingAddressFrom port: Int? = nil) {
        self.transport = transport
        keptFrom = port
    }

    /// The answer or the failure goes back to the search as it came.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            let response = try await transport.send(request)
            counts.answered[response.statusCode, default: 0] += 1
            return response
        } catch {
            switch Self.systemCode(of: error) {
            case Self.timedOut?: counts.timedOut += 1
            case let code?:
                counts.failed[code, default: 0] += 1
                if turnedAwayAt == nil, Counts.turnedAway(code), keptFrom == nil || request.url.port == keptFrom {
                    turnedAwayAt = request.url.host()
                }
            case nil: counts.other += 1
            }
            throw error
        }
    }

    /// `NSURLErrorTimedOut`, by its number: the failure is text by the time it gets here.
    private static let timedOut = -1001

    /// The system's code for a request that failed in transit. `URLSessionTransport` keeps such a failure as
    /// the text the system describes it with, which names the domain and the code ahead of everything else
    /// ("Error Domain=NSURLErrorDomain Code=-1009 ..."), so the code is read back out of that. Nil for any
    /// other failure, a stub's above all.
    static func systemCode(of error: any Error) -> Int? {
        guard case RecorderError.transport(let text) = error,
              let marker = text.range(of: "NSURLErrorDomain Code=") else { return nil }
        return Int(text[marker.upperBound...].prefix { $0 == "-" || $0.isASCII && $0.isNumber })
    }
}
