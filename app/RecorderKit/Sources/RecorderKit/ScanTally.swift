import Foundation

/// Passes a search's requests on to the transport it is given and counts how each came back, for the search's
/// line in the log (`ScanLog`): answered, by status; timed out; failed in transit, by the system's code. To the
/// search itself every one of those but a 200 is an address where no recorder lives (`Discovery.probe`), and
/// which of them it was is the one thing that tells a subnet with nobody on it from a phone that let nothing
/// out: a search reads that off the counts too (`Counts.turnedAwayWhole`).
///
/// Only counts are kept. Which address a request was for is not, and nothing of what was answered.
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

        /// Whether the requests counted here were turned away whole: at least one was made, and not one of
        /// them was answered, timed out, was cancelled, or was refused or dropped by an address.
        ///
        /// Each of those four is a request that was out for its time or got an answer of a kind. An answer,
        /// whatever its status. A timeout (-1001), which is how an address where nobody lives comes back: a
        /// search gives each a little over a second. A cancellation (-999), which is how the same silence
        /// comes back when the request has outlived that time and the search has ended it (`Discovery.probe`
        /// races each against a deadline of its own, since one was seen not to end on an iPhone). A
        /// connection the address refused (-1004) or dropped (-1005). On a subnet there are always addresses
        /// where nobody lives, so a look through one that came back with none of these is taken not to have
        /// reached the network: every request failed some other way.
        ///
        /// Written by what is absent, and not by the code such a failure carries. The one to expect is -1009:
        /// a session that does not wait for connectivity "fails immediately with an error, such as
        /// NSURLErrorNotConnectedToInternet" (Apple, `URLSessionConfiguration.waitsForConnectivity`), and
        /// "such as" names no list. Which code the system gives a request it turns away behind its question
        /// about the local network is in none of Apple's pages read for this (the technote TN3179, that
        /// property's page and its delegate call's), and has not been read off a phone.
        ///
        /// What this cannot tell: requests the system held and then let time out. Those count as timeouts,
        /// and a look made of them is a subnet with nobody on it.
        public var turnedAwayWhole: Bool {
            let wereOut = answered.values.reduce(0, +) + timedOut
                + Self.codesOfARequestThatWasOut.reduce(0) { $0 + failed[$1, default: 0] }
            return asked > 0 && wereOut == 0
        }

        /// The system's codes for a failure that says the request was out for its time or reached an
        /// address: timed out, should one be counted by its code; cancelled; refused; dropped.
        private static let codesOfARequestThatWasOut = [-1001, -999, -1004, -1005]

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

    public init(_ transport: any HTTPTransport) {
        self.transport = transport
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
            case let code?: counts.failed[code, default: 0] += 1
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
