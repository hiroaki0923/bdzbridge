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
    /// was read; when it was not, the host's line says why, as for any read.
    ///
    /// The list is handed to `keep` as it comes back, before the free space is asked, so that what the app holds
    /// is the list from the moment it is read. The free space is only shown, and cannot fail the list: a
    /// recorder that will not say leaves it unknown (`storage(of:)`), and silence loses the recorder, saying
    /// nothing (`learnTheFreeSpace`). The line of what went wrong is cleared once both are over.
    ///
    /// Nothing is asked when there is no recorder's client; whether to ask at all -- the recorder known to be
    /// away, the list read already -- is the app's to say.
    public func titles(keep: @MainActor ([RecordedTitle]) -> Void) async -> Bool {
        guard let link, let client = link.client as? RecorderClient else { return false }
        return await asked(Self.titlesLine, on: link) { _ in
            keep(try await client.allTitles())
            await self.learnTheFreeSpace(on: client, link)
        }.wentThrough
    }

    /// The free space read again, after a delete or with the list of recordings, and kept in the session for
    /// the screens. It is only shown, so a recorder that will not say is not an error. Silence is still silence,
    /// and loses the recorder, with nothing said.
    func learnTheFreeSpace(on client: RecorderClient, _ link: DeviceLink) async {
        do {
            link.session.learned(storage: try await Self.storage(of: client))
        } catch {
            link.lost()
        }
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
    static let stillRecording = "録画中のため削除できません。番組が終わるまでお待ちください。"

    /// A write: the recorder stops deleting this one to make room. What it came to, with its sentence, and
    /// whether the recordings are to be read again once the recorder answers (`readAgain`); `keep` is how the
    /// app's list shows it, called once the recorder has taken it.
    ///
    /// What a door turns away, with nothing sent, is said in the result and not on the line, which keeps what an
    /// earlier operation left there (`Reserved`): the link gone, no recorder's client in hand, or the recorder
    /// known to be away, each that the app is not connected (`whyNotConnected`). Otherwise one operation, as
    /// `DeviceLink.run` makes one, on the client in hand at the door. A check that says no has said why on the
    /// line, and the result says it again (`altered`); silence says that the protect may have arrived
    /// (`mayHaveArrived`), and anything else is said in the recorder's words, on the line and in the result.
    ///
    /// The recordings are to be read again after anything that failed with the recorder known to be away, the
    /// door that found it so among them: silence may have come after the recorder made the change, and the list
    /// is read again once it answers rather than guessed at. Not after a door that found no recorder to ask.
    public func protect(_ title: RecordedTitle, _ on: Bool, keep: @MainActor () -> Void) async
        -> (altered: Altered, readAgain: Bool) {
        guard let link else { return (.notDone(Self.notConnected), false) }
        guard let client = link.client as? RecorderClient else { return (.notDone(whyNotConnected), false) }
        guard !link.session.unreachable else { return (.notDone(whyNotConnected), true) }
        let came = await asked(on ? Self.protectingLine : Self.unprotectingLine, sending: Self.mayHaveArrived,
                               on: link) { _ in
            try await client.updateTitle(id: title.id, protected: on)
            keep()
        }
        return (altered(came, on: link), !came.wentThrough && link.session.unreachable)
    }

    /// A write, and not one that can be undone: the recording is gone from the recorder. What it came to, and
    /// whether the recordings are to be read again, as for `protect`; `keep` takes the row out of the app's list,
    /// called once the recorder has taken it, before the free space is read again under the same line
    /// (`learnTheFreeSpace`), which cannot fail the delete: it has happened whatever that says.
    ///
    /// The recorder answers a bare HTTP 500 for a recording it is still writing to, which on screen reads as a
    /// fault in the app. The screens do not offer it, but a row can be a few minutes old: one still being
    /// recorded is turned away before anything is sent, the result saying why (`stillRecording`) and the line
    /// left as it was, and the recordings are not to be read again for it. Then as `protect`: its doors, and
    /// silence saying that the delete may have arrived.
    public func delete(_ title: RecordedTitle, keep: @MainActor () -> Void) async
        -> (altered: Altered, readAgain: Bool) {
        guard let link else { return (.notDone(Self.notConnected), false) }
        if title.recording { return (.notDone(Self.stillRecording), false) }
        guard let client = link.client as? RecorderClient else { return (.notDone(whyNotConnected), false) }
        guard !link.session.unreachable else { return (.notDone(whyNotConnected), true) }
        let came = await asked(Self.deletingTitleLine, sending: Self.mayHaveArrived, on: link) { _ in
            try await client.deleteTitle(id: title.id)
            keep()
            await self.learnTheFreeSpace(on: client, link)
        }
        return (altered(came, on: link), !came.wentThrough && link.session.unreachable)
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
    /// Playing turns a recorder in network standby on first and waits for it (`RecorderClient.play`), saying on
    /// the line how long it has been (`poweringOnLine`). One still not on by the end of the wait, or a pause or a
    /// stop sent to one in standby, answers 880, which the session keeps (`SessionState.needsPower`) for the
    /// sheet to offer to turn it on. What it came to, with its sentence.
    ///
    /// Turned away at the door as a protect is (`protect`), the result saying that the app is not connected and
    /// the line left as it was; the offer to turn the recorder on is left as it was too, since nothing was asked.
    /// Past the door the offer goes, whatever becomes of the request. Then one operation, as `DeviceLink.run`
    /// makes one, on the client in hand at the door, whose silence is said as a read's; what the check or a
    /// failure said is in the result as well as on the line (`altered`).
    @discardableResult
    public func play(_ title: RecordedTitle, _ operation: String) async -> Altered {
        guard let link else { return .notDone(Self.notConnected) }
        guard let client = link.client as? RecorderClient, !link.session.unreachable else {
            return .notDone(whyNotConnected)
        }
        let owner = link.owner
        link.session.powerNeeded(false)
        let came = await asked(operation == "stop" ? Self.stoppingLine : Self.playingLine, on: link) { line in
            do {
                if operation == "play" {
                    try await client.play(titleID: title.id) { @MainActor seconds in
                        if let line { owner?.updateActivity(line, to: Self.poweringOnLine(seconds)) }
                    }
                } else {
                    try await client.playControl(titleID: title.id, operation: operation)
                }
            } catch let error as any DeviceError where error.failure == .needsPower {
                link.session.powerNeeded(true)
                throw error
            }
        }
        return altered(came, on: link)
    }

    /// Turns the recorder on, which also turns on the television attached to it, and takes the offer to do so
    /// away once the recorder has said it is on. As `play` otherwise.
    @discardableResult
    public func powerOn() async -> Altered {
        guard let link else { return .notDone(Self.notConnected) }
        guard let client = link.client as? RecorderClient, !link.session.unreachable else {
            return .notDone(whyNotConnected)
        }
        let came = await asked(Self.turningOnLine, on: link) { _ in
            _ = try await client.powerOn()
            link.session.powerNeeded(false)
        }
        return altered(came, on: link)
    }

    // MARK: - one request

    /// One thing the reader asked of the recorder, as `DeviceLink.run` makes it, written out so that what is asked
    /// in it can be the operation's own: under `line`, the recorder made sure of first (`DeviceLink.check`),
    /// then `work`, handed the line's token. What `work` returned, or how it failed: the check said no -- it has
    /// said why -- or `work` failed, which is said (`DeviceLink.say`): `sending` is the sentence for silence met
    /// by what changes the recorder, nil for a read. Going through clears the line of what went wrong, once
    /// `work` is over.
    ///
    /// `work` asks the client in hand at the operation's door, which is the one the check is asked with: nothing
    /// suspends between the door and the check.
    func asked<T>(_ line: String, sending: String? = nil, on link: DeviceLink,
                  _ work: @MainActor (Activities.Token?) async throws -> T) async -> Result<T, OperationFailure> {
        let owner = link.owner
        return await link.underALine(line) { token in
            switch await link.check() {
            case .notUp(let why):
                return .failure(.notSent(why))
            case .up:
                do {
                    let value = try await work(token)
                    owner?.problem = nil
                    return .success(value)
                } catch {
                    return .failure(link.say(OperationFailure(error, sending: sending), ofARead: sending == nil))
                }
            }
        }
    }

    /// What a write asked through `asked` came to, for its result: done, or not, saying what the line says of it.
    /// What was sent and failed is the link's sentence on the line; where the check before it said no, whatever
    /// it left there, and that the app is not connected where it left nothing -- the reservations' rule
    /// (`Reserved`).
    func altered<T>(_ came: Result<T, OperationFailure>, on link: DeviceLink) -> Altered {
        switch came {
        case .success:
            .done(saying: nil)
        case .failure(let failure):
            .notDone(failure.sentence ?? link.owner?.problem ?? whyNotConnected)
        }
    }
}

extension Result {
    /// Whether what was asked went through.
    var wentThrough: Bool {
        if case .success = self { return true }
        return false
    }
}
