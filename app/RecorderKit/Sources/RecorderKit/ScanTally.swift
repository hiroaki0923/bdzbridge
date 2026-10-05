import Foundation

/// Passes a search's requests on to the transport it is given and counts how each came back, for the search's
/// line in the log (`ScanLog`): answered, by status; timed out; failed in transit, by the system's code. To the
/// search itself every one of those but a 200 is an address where no recorder lives (`Discovery.probe`), and
/// which of them it was is the one thing that tells a subnet with nobody on it from a phone that let nothing out.
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
