import Foundation

/// What is asked of the recorder's recordings, beside its reservations: reading them with the free space, one
/// recording's details, protecting and deleting one, playing it on the television the recorder is attached to,
/// and turning the recorder on. The steps, and what each says on the host's screen; what the app keeps of the
/// list is handed to it as the step that changes it goes through (`keep`), and the screens are the app's.
extension RecorderDriver {
    // MARK: - the list and the free space

    /// The line on screen while the recordings are read.
    static let titlesLine = "録画一覧を取得中"

    /// Reads every recording, in pages of 200, and then the free space, which is read again with the list. One
    /// operation, as `DeviceLink.run` makes one: under a line of its own, the recorder made sure of first, the
    /// list read on the client in hand at the door, which is the one the check is asked with. Whether the list
    /// was read; when it was not, the host's line says why, as for any read. After a check that heard something
    /// in place of the recorder saying which it is, nothing is read, as for the reservations: what it heard is
    /// what the read fails as, and the next check asks again (`asked`).
    ///
    /// The list is handed to `keep` as it comes back, before the free space is asked, so that what the app holds
    /// is the list from the moment it is read; the line of what went wrong is cleared then. The free space is a
    /// step after it, under the same line, and is only shown: it cannot fail the list, a recorder that will not
    /// say leaves it unknown (`storage(of:)`), and its silence is said as any read's (`learnTheFreeSpace`), on
    /// the line the list cleared, where it stays.
    ///
    /// Nothing is asked when there is no recorder's client; whether to ask at all -- the recorder known to be
    /// away, the list read already -- is the app's to say.
    ///
    /// A list that comes back once the recorder has been let go of -- another has described itself, or another
    /// address was chosen -- is not handed to `keep`, nor is the free space read after it, and the line is left
    /// as it is: it is about the recorder let go of. Its silence is neither said nor taken for the recorder in
    /// play (`asked`).
    ///
    /// One read at a time, as for the reservations (`folded`): the tab, a pull-down, the search and a connect ask
    /// for the list, and these come together. Whoever asks while a read is out for the same recorder, on the same
    /// client, gets whether it was read, and the list the first handed to its `keep` is the one kept; no second
    /// request is sent. One out for a recorder let go of, or on a client a connect has since put another in
    /// place of, is waited for before the list is read again, so that two clients do not ask the recorder at
    /// once: the newcomer's list, which its connect reads (`LinkHost.reached`), is read once that one is back.
    public func titles(keep: @escaping @MainActor ([RecordedTitle]) -> Void) async -> Bool {
        guard let link, let client = link.client as? RecorderClient else { return false }
        return await folded(\.titlesReading, on: link, client) { await self.readTitles(on: link, keep: keep) }
    }

    /// The read itself, and the free space after it.
    private func readTitles(on link: DeviceLink, keep: @MainActor ([RecordedTitle]) -> Void) async -> Bool {
        let began = link.generation
        return await link.underALine(Self.titlesLine) { _ in
            let came = await self.asked(nil, .aRead, on: link, since: began) { _, client -> RecorderClient? in
                let list = try await client.allTitles()
                guard !link.letGo(since: began) else { return nil }
                keep(list)
                return client
            }
            guard case .went(let read) = came, let client = read else { return false }
            await self.learnTheFreeSpace(on: client, link, since: began)
            return true
        }
    }

    /// The free space read again, after a delete or with the list of recordings, and kept in the session for
    /// the screens: a step of that operation, after its own clear of the line. It is only shown, so a recorder
    /// that will not say is not an error. Silence is still silence, and is said as any read's is, once
    /// (`DeviceLink.say`, `takesSilenceOnARead`): the recorder lost, and the line saying that it did not answer,
    /// where nothing clears it after. What comes back once the recorder has been let go of since `began` is about
    /// that one: nothing is learned of it, and its silence is neither said nor taken.
    func learnTheFreeSpace(on client: RecorderClient, _ link: DeviceLink, since began: Int) async {
        do {
            let storage = try await Self.storage(of: client)
            guard !link.letGo(since: began) else { return }
            link.session.learned(storage: storage)
        } catch {
            _ = link.say(OperationFailure(error, sending: nil), since: began, ofARead: true)
        }
    }

    /// What pulling the recordings or the keyword conditions down asks for, as pulling the reservations down
    /// does (`refreshReservations`): when something can be written to the recorder (`canBeAsked`), `read`, which
    /// reads the list now. When nothing can, the reader has asked for it to be tried again: a connect. So it is
    /// for a recorder given up on, for one the app is not connected to, and for one whose last connect it
    /// answered busy with somebody else as it was asked which it is, for which no 再接続 is offered, the app being
    /// connected from the attach before. A connect under way is not made again (`DeviceLink.connect`).
    ///
    /// The list itself comes once, either way. The screens read theirs as the app becomes connected, so after a
    /// connect that makes it so the list is theirs to read. An app connected all through -- a reconnect under way
    /// as it comes back from the background or the network changes, or one answered busy -- has nothing read
    /// for it as the connect ends, which reads only the reservations: there `read` is asked once the pull-down's
    /// own connect is over, or at once beside a connect under way, whose client sends it after what the attach
    /// asks, as any read is sent. Not once that connect has let go of the recorder, another having described
    /// itself at the address: the newcomer's connect reads the lists the screens had read (`LinkHost.reached`),
    /// and the list is not read from it twice.
    public func refresh(reading read: @MainActor () async -> Void) async {
        guard let link else { return }
        guard canBeAsked(on: link) else {
            let connectedThrough = link.session.connected && !link.offline
            let began = link.generation
            await link.connect()
            if connectedThrough, !link.letGo(since: began) { await read() }
            return
        }
        await read()
    }

    // MARK: - one recording

    /// What the recorder says a recording is about, or nil when it was not asked or could not say. Asked as a
    /// recording's sheet opens, which is also the moment to wake a recorder that has gone to sleep: what the
    /// reader opened it for -- playing, protecting, deleting -- then goes straight through.
    ///
    /// No line of its own, as the question of what a reservation would clash with (`conflicts`): it is asked
    /// before anybody has asked for anything, and the line of what went wrong is left as it is, whatever the
    /// answer. With no recorder's client, or the recorder silent at the last ask, nothing is asked. The recorder
    /// is made sure of first (`DeviceLink.ensureUp`), on the client in hand at the door. Silence loses the
    /// recorder and says nothing, unless the link asks through another client by then: nothing on the strip
    /// says this is out, so another recorder can be chosen meanwhile, and a connect can make a new client, and
    /// silence met by a client the link no longer holds says nothing of the recorder in play. Anything else is
    /// no details, said nowhere.
    public func detail(of title: RecordedTitle) async -> (summary: String, details: [String])? {
        guard let link, let client = link.client as? RecorderClient, !link.session.unreachable,
              await link.ensureUp() else { return nil }
        do {
            return try await client.titleDetail(id: title.id)
        } catch let error as any DeviceError where error.failure == .silent {
            if client === link.client { link.lost() }
            return nil
        } catch {
            return nil
        }
    }

    /// The lines on screen while a recording is protected, or its protection taken off, and while one is deleted.
    static let protectingLine = "保護中"
    static let unprotectingLine = "保護を解除中"
    static let deletingTitleLine = "削除中"

    /// Said when a recording still being recorded is asked to be deleted.
    nonisolated static let stillRecording = "録画中のため削除できません。番組が終わるまでお待ちください。"
    /// Said when a recording that is protected is asked to be deleted: its protection is to come off first.
    public nonisolated static let protectedCannotBeDeleted = "保護されているため削除できません。先に保護を解除してください。"

    /// Why a recording cannot be deleted now, or nil when it can, by the row as the phone holds it: one still
    /// being recorded, by its own flag -- the recorder answers a bare HTTP 500 for a recording it is still
    /// writing to, which on screen reads as a fault in the app -- and then one protected, which the recorder
    /// refuses to delete. For the door of `delete`, and for the screens, which offer no delete the door would
    /// turn away and say why from here: the rule is written once.
    ///
    /// A row is as old as the list it was read in. One protected since on the recorder's own screen is not seen
    /// here, and its delete goes, the recorder's answer being said; one whose protection was taken off there is
    /// turned away until the list is read again. What the recordings of a USB disk add -- the disk the list was
    /// read from, and when -- a row does not carry: they come as a parameter of this, not as a rule beside it.
    public nonisolated static func whyNot(deleting title: RecordedTitle) -> String? {
        if title.recording { return stillRecording }
        return title.protected ? protectedCannotBeDeleted : nil
    }

    /// A write: the recorder stops deleting this one to make room. What it came to, with its sentence, and
    /// whether the recordings are to be read again once the recorder answers (`readAgain`); `keep` is how the
    /// app's list shows it, called once the recorder has taken it.
    ///
    /// What a door turns away, with nothing sent, is said in the result and not on the line, which keeps what an
    /// earlier operation left there (`Reserved`): the link gone, no recorder's client in hand, the recorder
    /// known to be away, or nothing that can be written to it (`canBeAsked`) -- a connect being under way, or
    /// the recorder not having said which it is -- each that the app is not connected (`whyNotConnected`), as
    /// for a reservation's delete or change. Otherwise one operation, as `DeviceLink.run` makes one, on the client
    /// in hand at the door. A check that says no has said why on the line, and the result says it again
    /// (`altered`); one that heard something in place of the recorder saying which it is has nothing sent
    /// (`asked`), and what it heard is said on the line and in the result. Silence says that the protect may have
    /// arrived (`mayHaveArrived`), and anything else is said in the recorder's words, on the line and in the
    /// result.
    ///
    /// The protect is for the recorder in play as it was asked for (`asked`). Let go of before it is handed to
    /// the client, nothing is sent and the result says why (`whyLetGo`). Handed over, it goes whatever happens
    /// after -- the client sends what it was given -- and its answer is taken as across a let-go, as a
    /// reservation's delete takes one: done, with the newcomer's line left and `keep` not called, since the list
    /// on screen is the newcomer's; silence said, since it may have arrived, losing nobody, and the recordings
    /// not to be read again for it; a refusal said.
    ///
    /// The recordings are to be read again once the recorder answers only after the protect met silence on its
    /// way to the recorder in play: it may have arrived, and the list is read again rather than guessed at. Not
    /// after anything that was never sent -- turned away at a door, by the check, or across a let-go -- which
    /// changed nothing on the recorder, however the app stands with it; nor after silence across a let-go,
    /// which is not the recorder in play's.
    public func protect(_ title: RecordedTitle, _ on: Bool, keep: @MainActor () -> Void) async
        -> (altered: Altered, readAgain: Bool) {
        guard let link else { return (.notDone(Self.notConnected), false) }
        guard link.client is RecorderClient else { return (.notDone(whyNotConnected), false) }
        guard !link.session.unreachable else { return (.notDone(whyNotConnected), false) }
        guard canBeAsked(on: link) else { return (.notDone(whyNotConnected), false) }
        let began = link.generation
        let came = await asked(on ? Self.protectingLine : Self.unprotectingLine,
                               .aWrite(sending: Self.mayHaveArrived), on: link, since: began) { _, client in
            try await client.updateTitle(id: title.id, protected: on)
            if !link.letGo(since: began) { keep() }
        }
        return (altered(came, on: link), came.silentAfterSending && !link.letGo(since: began))
    }

    /// A write, and not one that can be undone: the recording is gone from the recorder. What it came to, and
    /// whether the recordings are to be read again, as for `protect`; `keep` takes the row out of the app's list,
    /// called once the recorder has taken it, and the line of what went wrong is cleared then, before the free
    /// space is read again under the same line (`learnTheFreeSpace`), which cannot fail the delete: it has
    /// happened whatever that says, and silence on it is said on the line, where it stays.
    ///
    /// A recording that cannot be deleted now (`whyNot(deleting:)`) -- still being recorded, or protected -- is
    /// turned away before anything is sent, the result saying why and the line left as it was, and the
    /// recordings are not to be read again for it. The screens do not offer it, but a row can be a few minutes
    /// old. Then as `protect`: its doors, silence saying that the delete may have arrived, and an answer across a
    /// let-go, which neither takes the row out nor reads the free space.
    public func delete(_ title: RecordedTitle, keep: @MainActor () -> Void) async
        -> (altered: Altered, readAgain: Bool) {
        guard let link else { return (.notDone(Self.notConnected), false) }
        if let why = Self.whyNot(deleting: title) { return (.notDone(why), false) }
        guard link.client is RecorderClient else { return (.notDone(whyNotConnected), false) }
        guard !link.session.unreachable else { return (.notDone(whyNotConnected), false) }
        guard canBeAsked(on: link) else { return (.notDone(whyNotConnected), false) }
        let began = link.generation
        return await link.underALine(Self.deletingTitleLine) { _ in
            let came = await self.asked(nil, .aWrite(sending: Self.mayHaveArrived), on: link,
                                        since: began) { _, client -> RecorderClient? in
                try await client.deleteTitle(id: title.id)
                guard !link.letGo(since: began) else { return nil }
                keep()
                return client
            }
            if case .went(let deleted) = came, let client = deleted {
                await self.learnTheFreeSpace(on: client, link, since: began)
            }
            return (self.altered(came, on: link), came.silentAfterSending && !link.letGo(since: began))
        }
    }

    // MARK: - playback and power

    /// The lines on screen while a recording is played or paused, while it is stopped, and while the recorder is
    /// turned on.
    static let playingLine = "再生を指示中"
    static let stoppingLine = "停止中"
    static let turningOnLine = "電源を入れています"

    /// The line while a play waits for the recorder it has turned on, with the seconds waited so far.
    nonisolated static func poweringOnLine(_ seconds: Int) -> String {
        "レコーダーの電源を入れています（\(seconds) 秒）"
    }

    /// Playback happens on the television the recorder is attached to, not here. `operation` is the recorder's own
    /// word: `play`, `pause` or `stop`; `pause` toggles, so the same call resumes.
    ///
    /// Playing turns a recorder in network standby on first and waits for it (`playTurningItOn`), saying on the
    /// line how long it has been (`poweringOnLine`). One still not on by the end of the wait, or a pause or a
    /// stop sent to one in standby, answers 880, which the session keeps (`SessionState.needsPower`) for the
    /// sheet to offer to turn it on. What it came to, with its sentence.
    ///
    /// Turned away at the door as a protect is (`protect`), the result saying that the app is not connected and
    /// the line left as it was; the offer to turn the recorder on is left as it was too, since nothing was asked.
    /// Past the door the offer goes, whatever becomes of the request. Then one operation, as `DeviceLink.run`
    /// makes one, on the client in hand at the door: something that acts on the recorder, so not sent after a
    /// check that heard something else than the recorder saying which it is (`asked`), but whose silence is said
    /// as a read's; what the check or a failure said is in the result as well as on the line (`altered`). For
    /// the recorder in play as it was asked for, as a protect is, the play after the power wait among it: a play
    /// by its number to another recorder would play another recording. The offer is not set by an answer across
    /// a let-go, which is about the recorder let go of.
    @discardableResult
    public func play(_ title: RecordedTitle, _ operation: String) async -> Altered {
        guard let link else { return .notDone(Self.notConnected) }
        guard link.client is RecorderClient, !link.session.unreachable, canBeAsked(on: link) else {
            return .notDone(whyNotConnected)
        }
        let began = link.generation
        link.session.powerNeeded(false)
        let came = await asked(operation == "stop" ? Self.stoppingLine : Self.playingLine, .aWrite(sending: nil),
                               on: link, since: began) { line, client in
            do {
                if operation == "play" {
                    try await self.playTurningItOn(title, on: client, link, since: began, line: line)
                } else {
                    try await client.playControl(titleID: title.id, operation: operation)
                }
            } catch let error as any DeviceError where error.failure == .needsPower {
                if !link.letGo(since: began) { link.session.powerNeeded(true) }
                throw error
            }
        }
        return altered(came, on: link)
    }

    /// A play, turning a recorder in network standby on first, in the steps the recorder's client offers, so
    /// that what is asked between them is the driver's. Only an 880 turns it on: the power state is not asked
    /// first, which would be one request more on every play of a recorder that is already on, and the demo's
    /// recorder does not report one. Once it is told to come on, `X_GetPlayStatus` is asked every
    /// `powerOnInterval` until `powerstatus` says `PowerOn`, and the play is sent again; after `powerOnLimit` it
    /// is sent regardless, and the 880 of a recorder still in standby is thrown. The line, when there is one,
    /// says the seconds waited so far, each time round.
    ///
    /// The power-on and the play after the wait go only to the recorder the play began with, and only while it
    /// may be written to: let go of since `began` -- another has described itself during the wait -- or heard
    /// in place of saying which it is by a check meanwhile (`DeviceLink.mayBeSent`), and nothing more is sent,
    /// the play turned away with why (`TurnedAway`: `whyLetGo`, `whyNotSent`).
    private func playTurningItOn(_ title: RecordedTitle, on client: RecorderClient, _ link: DeviceLink,
                                 since began: Int, line: Activities.Token?) async throws {
        do {
            try await client.playControl(titleID: title.id, operation: "play")
            return
        } catch let error as any DeviceError where error.failure == .needsPower {}
        try mayGoOn(link, since: began)
        try await client.powerOn()
        let started = Date()
        while Date().timeIntervalSince(started) < powerOnLimit {
            let waited = Int(Date().timeIntervalSince(started))
            if let line { link.owner?.updateActivity(line, to: Self.poweringOnLine(waited)) }
            try await Task.sleep(for: powerOnInterval)
            if try await client.playStatus()["powerstatus"] == "PowerOn" { break }
        }
        try mayGoOn(link, since: began)
        try await client.playControl(titleID: title.id, operation: "play")
    }

    /// Throws why nothing more is to be sent for an operation that began at `began`, part way through: the
    /// recorder let go of since, or not to be written to now.
    private func mayGoOn(_ link: DeviceLink, since began: Int) throws {
        guard !link.letGo(since: began) else { throw TurnedAway(why: whyLetGo(on: link)) }
        guard link.mayBeSent else { throw TurnedAway(why: whyNotSent(on: link)) }
    }

    /// Turns the recorder on, which also turns on the television attached to it, and takes the offer to do so
    /// away once the recorder has said it is on. As `play` otherwise.
    @discardableResult
    public func powerOn() async -> Altered {
        guard let link else { return .notDone(Self.notConnected) }
        guard link.client is RecorderClient, !link.session.unreachable, canBeAsked(on: link) else {
            return .notDone(whyNotConnected)
        }
        let began = link.generation
        let came = await asked(Self.turningOnLine, .aWrite(sending: nil), on: link, since: began) { _, client in
            _ = try await client.powerOn()
            if !link.letGo(since: began) { link.session.powerNeeded(false) }
        }
        return altered(came, on: link)
    }

    // MARK: - one request

    /// What is asked through `asked`, for the check before it and for its failure: a read of a list, or
    /// something that acts on the recorder, `sending` being the sentence for its silence -- nil where that is
    /// said as a read's, for playback and the power.
    enum Asking {
        case aRead
        case aWrite(sending: String?)
    }

    /// What an operation asked through `asked` came to.
    enum Asked<T> {
        /// It went through, and what it brought back.
        case went(T)
        /// Something that acts on the recorder, not sent after the check before it, and why, for its result
        /// (`whyNotSent`).
        case notSent(String)
        /// The check said no, or what was asked failed, as the link tells it.
        case failed(OperationFailure)

        /// Whether it went through.
        var wentThrough: Bool {
            if case .went = self { return true }
            return false
        }

        /// Whether what was sent met silence: it may have arrived.
        var silentAfterSending: Bool {
            if case .failed(.silentAfterSending) = self { return true }
            return false
        }

        /// Whether the recorder answered what was sent: it went through, or was refused.
        var answered: Bool {
            switch self {
            case .went, .failed(.refused): true
            default: false
            }
        }
    }

    /// Thrown by a step of an operation that turns the rest of it away before a later request, with the sentence
    /// for its result: nothing more is sent, and the link says nothing of it.
    struct TurnedAway: Error {
        let why: String
    }

    /// One thing the reader asked of the recorder, as `DeviceLink.run` makes it, written out so that what is asked
    /// in it can be the operation's own: under `line` -- nil for a step of an operation that has put up its own
    /// --, the recorder made sure of first (`DeviceLink.check`),
    /// then `work`, handed the line's token and the client the check was asked with. What `work` returned, or
    /// why not: the check said no -- it has said why -- or `work` was turned away part way (`TurnedAway`), or
    /// failed, which is said (`DeviceLink.say`), silence on something sent in the sentence `asking` gives. Going
    /// through clears the line of what went wrong, once `work` is over.
    ///
    /// After a check that heard something in place of the recorder saying which it is -- busy with somebody
    /// else, a fault (`DeviceLink.heardInstead`) -- nothing goes, as for the reservations and the television: a
    /// read fails with what it heard, which the link says; something that acts on the recorder is not sent
    /// (`DeviceLink.mayBeSent`), and what was heard goes on the line, being the recorder's answer, outside any
    /// clear of it, or with nothing heard -- the client not one an attach went through -- the result says that
    /// the app is not connected (`whyNotSent`). The check after such a check asks however lately the recorder
    /// answered (`DeviceLink.checksAgain`).
    ///
    /// `began` is the count the operation noted at its door (`DeviceLink.generation`): what is asked is for the
    /// recorder in play then. Something that acts on the recorder, let go of by the time the check has answered,
    /// is not sent, and says why (`whyLetGo`), whatever the check said. What was handed to the client goes
    /// whatever happens after -- the client sends what it was given -- and what comes back once the recorder has
    /// been let go of is about that one: a read's list is not handed back (`OperationFailure.letGoMeanwhile`),
    /// something that acts on it is done, and the line, which is the newcomer's, is not cleared either way; a
    /// failure is said by that count (`DeviceLink.say(_:since:ofARead:)`), silence on something sent losing
    /// nobody. `work` reads the count too, for what it keeps. A client made anew for the same recorder meanwhile
    /// lets go of nothing.
    func asked<T>(_ line: String?, _ asking: Asking, on link: DeviceLink, since began: Int,
                  _ work: @MainActor (Activities.Token?, RecorderClient) async throws -> T) async -> Asked<T> {
        let owner = link.owner
        let read: Bool
        if case .aRead = asking { read = true } else { read = false }
        return await link.underALine(line) { token in
            switch await link.check(evenIfRecent: link.checksAgain) {
            case .notUp(let why):
                // Something that acts on the recorder, let go of while the check was out, says so, as a reservation
                // does: what the check met was the recorder let go of.
                if !read, link.letGo(since: began) { return .notSent(self.whyLetGo(on: link)) }
                return .failed(.notSent(why))
            case .up(let checked):
                guard let client = checked as? RecorderClient else { return .notSent(self.whyNotConnected) }
                var sending: String?
                if case .aWrite(let silence) = asking {
                    guard !link.letGo(since: began) else { return .notSent(self.whyLetGo(on: link)) }
                    guard link.mayBeSent else { return .notSent(self.whyNotSent(on: link)) }
                    sending = silence
                }
                do {
                    if read, let heard = link.heardInstead { throw heard }
                    let value = try await work(token, client)
                    if link.letGo(since: began) { return read ? .failed(.letGoMeanwhile) : .went(value) }
                    owner?.problem = nil
                    return .went(value)
                } catch let away as TurnedAway {
                    return .notSent(away.why)
                } catch {
                    return .failed(link.say(OperationFailure(error, sending: sending), since: began, ofARead: read))
                }
            }
        }
    }

    /// A read of a list that is out, for whoever asks for the same list meanwhile (`folded`): under which count of
    /// recorders let go of (`DeviceLink.generation`) and on which client it went out, for which disk -- nil for
    /// the one every read so far is of, so that a read of one disk is never taken for a read of another -- and
    /// which read it is, by the count of those begun, which tells the one out from one begun after it.
    struct ReadOut<T: Sendable> {
        let generation: Int
        let client: ObjectIdentifier
        let destination: String?
        let number: Int
        let value: Task<T, Never>
    }

    /// One read of a list at a time, kept at `out`, as the reservations' read is kept (`reading`): whoever asks
    /// while one is out under the same count, on the same client and for the same disk, is handed what it came
    /// to, and nothing is sent again. One that is out otherwise -- for a recorder let go of, or on a client a
    /// connect has since put another in place of -- is waited for first, whatever it comes to, its answer being
    /// another's: two clients do not ask the recorder at once, and the read asked now goes once the last is
    /// back. A read begun is let go of as it ends.
    func folded<T: Sendable>(_ out: ReferenceWritableKeyPath<RecorderDriver, ReadOut<T>?>, on link: DeviceLink,
                   _ client: RecorderClient, destination: String? = nil,
                   _ read: @escaping @MainActor () async -> T) async -> T {
        while let reading = self[keyPath: out] {
            if reading.generation == link.generation, reading.client == ObjectIdentifier(client),
               reading.destination == destination {
                return await reading.value.value
            }
            _ = await reading.value.value
            if self[keyPath: out]?.number == reading.number { self[keyPath: out] = nil }
        }
        listReadsBegun += 1
        let number = listReadsBegun
        let value = Task { () -> T in
            defer { if self[keyPath: out]?.number == number { self[keyPath: out] = nil } }
            return await read()
        }
        self[keyPath: out] = ReadOut(generation: link.generation, client: ObjectIdentifier(client),
                                      destination: destination, number: number, value: value)
        return await value.value
    }

    /// What a write asked through `asked` came to, for its result: done, or not, saying why. What was sent and
    /// failed is the link's sentence on the line; where the check before it said no, whatever it left there, and
    /// that the app is not connected where it left nothing -- the reservations' rule (`Reserved`).
    func altered<T>(_ came: Asked<T>, on link: DeviceLink) -> Altered {
        switch came {
        case .went:
            .done(saying: nil)
        case .notSent(let why):
            .notDone(why)
        case .failed(let failure):
            .notDone(failure.sentence ?? link.owner?.problem ?? whyNotConnected)
        }
    }
}
