import Foundation

/// How something asked of a device through its link failed, for whoever asked to act on: what kind of failure
/// it was, and the sentence for it where the operation has one to say.
public enum OperationFailure: Error, Sendable, Equatable {
    /// Nothing was sent: the check before it said no, and why. No sentence comes with it, since what there is
    /// to say the check or the host has put on the line already. Only the check's no is carried here: what an
    /// operation says when its driver turns it away at a door of its own is not decided by this type.
    case notSent(NotUp)
    /// Something answered, and not as asked: a refusal, busy, an answer that could not be read. The kind is
    /// the device's (`DeviceError.failure`) and the sentence its own; nil, and the error as Swift describes
    /// it, for an error that is no device's.
    case refused(DeviceFailure?, sentence: String)
    /// Silence on something that changes the device: it may have arrived all the same, and is not sent again.
    /// The sentence is the one the operation gave for that.
    case silentAfterSending(sentence: String)
    /// Silence on a read: nothing is in doubt but whether the device is there. The sentence is the error's own.
    case silentOnARead(sentence: String)

    /// What `error` is, thrown by a request that was sent. `sending` is the sentence to say if what was sent
    /// changes the device and met silence -- an operation gives its own, since what the reader is to check
    /// afterwards differs from one to the next -- and nil for a read.
    public init(_ error: any Error, sending: String?) {
        guard let error = error as? any DeviceError else {
            self = .refused(nil, sentence: String(describing: error))
            return
        }
        guard error.failure == .silent else {
            self = .refused(error.failure, sentence: error.explanation)
            return
        }
        if let sending {
            self = .silentAfterSending(sentence: sending)
        } else {
            self = .silentOnARead(sentence: error.explanation)
        }
    }

    /// What to put in front of the reader, or nil where the operation itself has nothing to say.
    public var sentence: String? {
        switch self {
        case .notSent: nil
        case .refused(_, let sentence), .silentAfterSending(let sentence), .silentOnARead(let sentence): sentence
        }
    }
}

/// What an operation asked of a device is made of, whichever device it is, beside the check before it (`check`)
/// and what silence leaves behind (`lost`), which are the link's already: the line on the screen while it is
/// out, and what is said and done about the way it failed. `run` is the four in the order an operation of one
/// request keeps; one of several requests is written on the parts themselves.
extension DeviceLink {
    /// Runs `body` under a line of its own on the host's screen, taken away when it ends; with no text, under
    /// whatever line is up already. `body` is handed the line's token, to say how far it has got, or nil with
    /// no line or no host. The host is read once, here: the line is taken away from the host it was put up
    /// on, though the link has another by then, or none.
    public func underALine<T>(_ text: String?, _ body: @MainActor (Activities.Token?) async -> T) async -> T {
        let owner = owner
        let line = text.flatMap { owner?.beginActivity($0) }
        defer { if let line { owner?.endActivity(line) } }
        return await body(line)
    }

    /// Puts how something that was sent failed where the screens read it, and leaves the link where silence
    /// leaves it: given up until the network changes or the reader asks. The device is lost before the line is
    /// written. Silence on something sent is always said, in the operation's sentence: it may have arrived.
    /// Silence on a read is the device's rule (`LinkDriver.takesSilenceOnARead`): where the driver says no,
    /// nothing is touched, neither the link nor the line. A refusal is said in the device's words and the
    /// device kept, since it answered. Nothing is said for what was not sent: the check has said it.
    ///
    /// Apart from telling what a failure is (`OperationFailure.init`), so that an operation handed an outcome
    /// rather than an error can say it here all the same. Hands back what it was given, for a caller that
    /// tells, says and answers in one expression.
    @discardableResult
    public func say(_ failure: OperationFailure) -> OperationFailure {
        switch failure {
        case .notSent:
            break
        case .refused(_, let sentence):
            owner?.problem = sentence
        case .silentAfterSending(let sentence):
            lost()
            owner?.problem = sentence
        case .silentOnARead(let sentence):
            guard driver.takesSilenceOnARead(self) else { break }
            lost()
            owner?.problem = sentence
        }
        return failure
    }

    /// One thing asked of the device, as the reader asked for it: under `line` when it has one of its own, the
    /// device made sure of first (`check`), then `work`. What `work` returned, or how it failed.
    ///
    /// The line goes up before the check, so that the screen says what was asked for from the moment it was.
    /// When the check says no, `work` is not run and nothing more is written: the line of what went wrong is
    /// the check's. Going through clears that line; it is not cleared on the way in, where it would wipe the
    /// failure of the request before. A failure is said (`say`). `sending` is the sentence for silence met by
    /// what changes the device, nil for a read. `work` is handed the client the check made sure of and the
    /// token of the line put up here, nil with none.
    public func run<T>(line: String? = nil, sending: String? = nil,
                       _ work: @MainActor (_ client: any LinkClient, _ line: Activities.Token?) async throws -> T)
        async -> Result<T, OperationFailure> {
        // Read once, as the line's is: what went wrong is cleared on the host the operation began under.
        let owner = owner
        return await underALine(line) { token in
            switch await self.check() {
            case .notUp(let why):
                return .failure(.notSent(why))
            case .up(let client):
                do {
                    let value = try await work(client, token)
                    owner?.problem = nil
                    return .success(value)
                } catch {
                    return .failure(self.say(OperationFailure(error, sending: sending)))
                }
            }
        }
    }
}
