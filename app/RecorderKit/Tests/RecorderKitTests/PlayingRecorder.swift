import Foundation
import XCTest
import RecorderKit

/// A recorder that says who it is as the vectors' recorder does, and answers each SOAP action with the answers a
/// test gives for it, in turn and the last again once they run out; an action the test names as met by silence
/// with nothing at all; anything else with a 500, as a recorder that refuses what an attach reads besides its
/// description. It can be told to say nothing when asked who it is, or that it is busy with somebody else; to
/// say nothing to one more action from then on; and to hold the next request for one action until it is let go.
/// It puts down everything it was asked, answered or not: each action with its body, and an ask of who it is by
/// its file's name with an empty body, so that a test that counts what was asked, or finds nothing asked, counts
/// a look at who is there as well.
actor PlayingRecorder: HTTPTransport {
    private var answers: [String: [HTTPResponse]]
    private var silent: Set<String>
    private let description: String
    private(set) var actions: [String] = []
    private(set) var bodies: [String] = []
    private var saysWhoItIs = true
    private var busyWhenAsked = false
    private var holdsTheNext: String?
    private var held: CheckedContinuation<Void, Never>?

    init(_ answers: [String: [HTTPResponse]], silentTo silent: Set<String> = [], udn: String) throws {
        self.answers = answers
        self.silent = silent
        description = try Vectors.descriptionXML(udn: udn)
    }

    /// Puts down nothing of what was asked before now: what a connect asked.
    func forget() {
        actions = []
        bodies = []
    }

    /// Says nothing from now on when asked who it is, as a recorder that has left the network.
    func sayNothingOfWhoItIs() {
        saysWhoItIs = false
    }

    /// Busy with somebody else from now on whenever it is asked who it is: a 503, through every try.
    func beBusyWhenAskedWhoItIs() {
        busyWhenAsked = true
    }

    /// Says who it is again from now on.
    func sayWhoItIs() {
        saysWhoItIs = true
        busyWhenAsked = false
    }

    /// Says nothing to `action` from now on.
    func sayNothing(to action: String) {
        silent.insert(action)
    }

    /// The next request for `action` gets no answer until `letGo`, and then whatever it would get.
    func holdTheNext(_ action: String) { holdsTheNext = action }

    /// Whether a request is being held now.
    var isHolding: Bool { held != nil }

    /// Returns once a request is being held: waited for a bounded while, and a failure, thrown on, when none
    /// has come by then.
    nonisolated func whenHeld() async throws {
        var turns = 0
        while await !isHolding, turns < 100_000 {
            turns += 1
            await Task.yield()
        }
        guard await isHolding else {
            XCTFail("the request that was to be held never came")
            throw NothingHeld()
        }
    }

    func letGo() {
        held?.resume()
        held = nil
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.lastPathComponent != "description.xml" else {
            actions.append("description.xml")
            bodies.append("")
            guard saysWhoItIs else { throw RecorderError.transport("timed out") }
            guard !busyWhenAsked else { return HTTPResponse(statusCode: 503) }
            return HTTPResponse(statusCode: 200, body: Data(description.utf8))
        }
        let action = String((request.headers["SOAPACTION"] ?? "").split(separator: "#").last ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        actions.append(action)
        bodies.append(String(decoding: request.body ?? Data(), as: UTF8.self))
        if holdsTheNext == action {
            holdsTheNext = nil
            await withCheckedContinuation { held = $0 }
        }
        guard !silent.contains(action) else { throw RecorderError.transport("timed out") }
        guard var given = answers[action], let answer = given.first else { return HTTPResponse(statusCode: 500) }
        if given.count > 1 { given.removeFirst() }
        answers[action] = given
        return answer
    }
}

/// Thrown to end a test whose request never came to be held, once the failure is recorded.
private struct NothingHeld: Error {}
