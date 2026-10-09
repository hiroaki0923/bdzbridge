import Foundation

/// How something asked of a device through its link failed, for whoever asked to act on: what kind of failure
/// it was, and the sentence for it where the operation has one to say.
public enum OperationFailure: Error, Sendable, Equatable {
    /// Nothing was sent: the check before it said no, and why. No sentence comes with it, since what there is
    /// to say the check or the host has put on the line already. Only the check's no is carried here: what an
    /// operation says when its driver turns it away at a door of its own is not decided by this type, and
    /// the rule for it is written at `Reserved`.
    case notSent(NotUp)
    /// Not silence. Something answered, and not as asked -- a refusal, busy, an answer that could not be read
    /// -- or the request failed without the device: an address nothing can be sent to, an error that is no
    /// device's. The kind is the device's (`DeviceError.failure`) and the sentence its own; nil, and the error
    /// as Swift describes it, for an error that is no device's.
    case refused(DeviceFailure?, sentence: String)
    /// Silence on something that changes the device: it may have arrived all the same, and is not sent again.
    /// The sentence is the one the operation gave for that.
    case silentAfterSending(sentence: String)
    /// Silence on a read: nothing is in doubt but whether the device is there. The sentence is the error's own.
    case silentOnARead(sentence: String)
    /// What came back went through, but the device was let go of while it was out (`DeviceLink.letGo(since:)`):
    /// it is not about the device in play, and was neither kept nor said.
    case letGoMeanwhile

    /// What `error` is, thrown by the work. `sending` is the sentence to say if what was sent
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
}

/// What asking a device to record a programme came to, for the app to keep and a screen to say. The first
/// result a driver's operation hands back as a value: where there is something to say, the sentence is in it,
/// and whoever asked says it.
///
/// What an operation says at its own door -- where its driver turns it away before anything is sent -- goes
/// by what the operation hands back, and is one rule for every operation a driver hands the app:
///
/// - One whose result carries a sentence says in that result what its door turned away, and leaves the
///   device's line of what went wrong as it was: nothing was sent, and the line an earlier operation left
///   is not its to write over. Reserving a programme on a television is one. A waiting row sent again is
///   another: what it came to is handed back for the screen the reader asked on, and is nil where there is
///   nothing to say of the row -- one that is another device's, which its driver refuses as it refuses a
///   delete of another's reservation, and one that no longer waits. Changing a television's reservation is
///   a third (`Altered`), nil for a row of another device in the same way, and deleting one, on either
///   device, a fourth (`Altered` too). Reserving on the recorder hands back the same `Reserved`, and
///   changing one of its reservations the same `Altered`, nil for another device's row too.
/// - One that hands a screen nothing to say says nothing at its door: a sending of what waits, a read of
///   the list.
///
/// What was sent and failed is written on the line by the link, whichever operation it was
/// (`DeviceLink.say`), and what the check before an operation writes there is the check's; an operation
/// with a result says either again in it. A row a delete or a change finds gone or changed in the list just
/// read, or that the device answers it does not hold, is said in its result alone: the read that found it has
/// cleared the line.
///
/// Again means as the line holds it once the operation is over, and not as the operation wrote it: the
/// result is read off the line. So a read before a delete or a change that met silence the link does not
/// say -- the device known to be away already, its silence said once (`LinkDriver.takesSilenceOnARead`) --
/// leaves the line as it was, and the result repeats whatever is there, which can be what another operation
/// left: that something it sent may have arrived, among them. Both devices go by that, the television's
/// change and delete as the recorder's.
public enum Reserved: Sendable, Equatable {
    /// The device holds it: made now, or found there already. `saying` is what there is to add, in the
    /// device's own sentence -- that it was there already; what making it did beyond itself (another
    /// reservation left marked as sharing its time, the new one marked so itself) -- and nil for nothing.
    case made(saying: String?)
    /// Kept on the phone, and held: making it would stop other reservations from recording, and the reason
    /// on the row names them. Nothing was made. It is for the reader to say whether to make it all the same,
    /// which sending the row again is: the consent is to the reason as it stands on this row.
    case wouldStop(PendingReservation)
    /// Kept on the phone and not on the device: the row as it waits now, and what to say of it. With a reason
    /// on the row it waits for the reader, and `saying` is that reason, which the device turned it down
    /// with -- or, where the row was sent again and nothing could be asked about it, why it was not sent.
    /// With none it goes by itself the next time what waits is sent.
    case waiting(PendingReservation, saying: String)
    /// Not kept, and not known to have been made, and why.
    case notDone(String)
}

/// What asking a device to change a reservation it holds, or to delete one, came to, for a screen to say: a
/// result with its sentence, as `Reserved` is, and under the same rule for what its door turns away. A change
/// or a delete is made or it is not, and nothing of it is kept on the phone to go later, so there are two
/// cases and no third.
public enum Altered: Sendable, Equatable {
    /// The device holds the reservation as it was asked to, or no longer holds it. `saying` is what there is
    /// to add, in the device's own sentence -- reservations a change left marked as losing to others, the
    /// changed one itself among them -- and nil for nothing, as for every delete.
    case done(saying: String?)
    /// Not done, or not known to have been, and why.
    case notDone(String)
}

public extension Reserved {
    /// What is left to say of it on a screen that shows the waiting row itself, its reason with it, once the
    /// row has been sent again there: the reservations tab says this. Nil where the screen says it all.
    ///
    /// A row that was made has left what waits, and what there is to say of it is the sending's to say, as
    /// of any row that had been waiting. A row held for what it would stop from recording is said by its
    /// reason, whole: on that screen the answer only ever comes with names the reader did not press on, and
    /// sending the row once more is the consent to them. A row that waits says its own reason, so only
    /// another sentence is left to say: why it was not sent, or how it goes by itself.
    var besideItsRow: String? {
        switch self {
        case .made: nil
        case .wouldStop(let row): row.problem
        case .waiting(let row, let saying): saying == row.problem ? nil : saying
        case .notDone(let why): why
        }
    }

    /// Whether a row that waits is left for the reader with a reason this result has not said: it carries
    /// one, and that reason is not what is being said. Such a row was not sent at all -- `saying` is why
    /// nothing could be asked about it -- and the reason it was held with before still stands, so it does
    /// not go by itself the next time what waits is sent. A screen that said `saying` and went on as for any
    /// reservation kept would have it read as one that does: the programme's sheet stays open on the row.
    ///
    /// Not so for a row with no reason, which goes by itself, nor for one whose reason is what is being
    /// said, which the reader has then been told. The comparison `besideItsRow` makes, as a yes or a no.
    var leftForTheReader: Bool {
        switch self {
        case .waiting(let row, let saying): row.problem != nil && row.problem != saying
        case .made, .wouldStop, .notDone: false
        }
    }
}

/// What an operation asked of a device is made of, whichever device it is, beside the check before it (`check`)
/// and what silence leaves behind (`lost`), which are the link's already: the line on the screen while it is
/// out, and what is said and done about the way it failed. `run` is the four in the order an operation of one
/// request keeps. One of several requests can be written on the parts themselves, as the television's change
/// is, and the recorder's delete, change and reservation; the television's delete is not yet, and still puts up
/// its own line and says its own silence.
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
    /// device kept: it was not silence. Nothing is said for what was not sent: the check has said it.
    ///
    /// Apart from telling what a failure is (`OperationFailure.init`), so that an operation handed an outcome
    /// rather than an error can say it here all the same. Hands back what it was given, for a caller that
    /// tells, says and answers in one expression.
    ///
    /// `since` is the count an operation noted as it began (`generation`). When the device was let go of since
    /// then, silence is not the device's in play: silence on something sent is still said, since it may have
    /// arrived whatever became of the device, but loses nobody, and silence on a read is neither said nor taken.
    /// A refusal of something sent is said as ever: it is the answer to what the reader asked for. A read's
    /// (`ofARead`) is not, any more than what a read that went through brought back: it is about the device let
    /// go of, and the line is the newcomer's. A client made anew for the same device meanwhile moves nothing.
    public func say(_ failure: OperationFailure, since generation: Int? = nil,
                    ofARead: Bool = false) -> OperationFailure {
        let letGo = generation.map { letGo(since: $0) } ?? false
        switch failure {
        case .notSent, .letGoMeanwhile:
            break
        case .refused(_, let sentence):
            guard !(letGo && ofARead) else { break }
            owner?.problem = sentence
        case .silentAfterSending(let sentence):
            if !letGo { lost() }
            owner?.problem = sentence
        case .silentOnARead(let sentence):
            guard !letGo, driver.takesSilenceOnARead(self) else { break }
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
    /// what changes the device, nil for a read. `work` is handed the client that was in hand as the check was
    /// asked (`check`), which `evenIfRecent` is handed to.
    ///
    /// `since` is the count the operation noted as it began (`generation`), nil for one that does not ask. When
    /// the device was let go of since then, what `work` returned is not handed back and the line is not cleared
    /// (`OperationFailure.letGoMeanwhile`), and a failure is said by that count (`say(_:since:ofARead:)`), a read
    /// being one with no `sending`. A client made anew for the same device meanwhile lets go of nothing, and the
    /// value is handed back.
    public func run<T>(line: String? = nil, sending: String? = nil, evenIfRecent: Bool = false, since: Int? = nil,
                       _ work: @MainActor (_ client: any LinkClient) async throws -> T)
        async -> Result<T, OperationFailure> {
        // Read once, as the line's is: what went wrong is cleared on the host the operation began under.
        let owner = owner
        return await underALine(line) { _ in
            switch await self.check(evenIfRecent: evenIfRecent) {
            case .notUp(let why):
                return .failure(.notSent(why))
            case .up(let client):
                do {
                    let value = try await work(client)
                    if let since, self.letGo(since: since) { return .failure(.letGoMeanwhile) }
                    owner?.problem = nil
                    return .success(value)
                } catch {
                    return .failure(self.say(OperationFailure(error, sending: sending), since: since,
                                             ofARead: sending == nil))
                }
            }
        }
    }
}
