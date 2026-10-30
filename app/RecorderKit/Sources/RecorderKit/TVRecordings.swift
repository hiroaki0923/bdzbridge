import Foundation

extension RecordedTitle {
    /// A row of a television's list (`ScalarClient.recordings`), by what was measured of version 1.5: the uri, its
    /// name for the recording, as the id; the start with its offset written `+0900`; the length in `duration` and
    /// the size in `sizeMB`, since `fileSizeByte` is -1 on a large one; and `isProtected`, `isAlreadyPlayed` and
    /// `recordingInfo.isRecording` as the strings `true` and `false`. There is no `eventId`, no service id and no
    /// mode, and a resume point has not been seen.
    ///
    /// A row being recorded says nought for its length and its size, which do not grow until it ends: its size is
    /// none, and its length is not to be said (`lengthKnown`). The text may be absent, or there and empty, which is
    /// none either way. The genre is the first of `broadcastGenreInfo`, taken to be the recorder's code for one,
    /// level 1 times sixteen and level 2: which codes a television writes there has not been looked at beside its
    /// own screen, and what is no such code is no genre.
    ///
    /// Nil without a uri, or a start that reads as a time, so that such a row is left out, as a recorder's is,
    /// rather than the whole list refused for it.
    init?(televisionRow row: [String: ScalarValue]) {
        guard let uri = row["uri"]?.text, !uri.isEmpty,
              let start = row["startDateTime"]?.text.flatMap(RecorderTime.parse) else { return nil }
        func flag(_ value: ScalarValue?) -> Bool { value?.text == "true" }
        func said(_ value: ScalarValue?) -> String? { value?.text.flatMap { $0.isEmpty ? nil : $0 } }
        let recording = flag(row["recordingInfo"]?["isRecording"])
        var genre: Int?
        if case .list(let genres)? = row["broadcastGenreInfo"], let code = genres.first?["genreId"]?.whole,
           (0...255).contains(code) {
            genre = code
        }
        self.init(id: uri, title: row["title"]?.text ?? "", start: start,
                  durationSec: row["duration"]?["durationSec"]?.whole ?? 0, broadcastingType: 0, serviceID: 0,
                  qualityCode: 0, protected: flag(row["isProtected"]), isNew: !flag(row["isAlreadyPlayed"]),
                  recording: recording, destination: TVDriver.recordsTo,
                  sizeMB: recording ? nil : row["sizeMB"]?.whole, genreCode: genre, device: .tv,
                  channelName: said(row["channelName"]), summary: said(row["description"]?["summary"]),
                  details: said(row["description"]?["detail"]))
    }
}

/// What a read of a television's recordings comes to beside what its disk says it has used. A television's list
/// can lack what its own screen shows: empty for a minute or two after a restart, the disk full all the same, and
/// short of rows for as long as they are not played there. No other route to the list has been found, so the two
/// figures are all that says so.
public enum TVTitlesAccount: Sendable, Equatable {
    /// Nothing to say: the rows come to what the disk has used, within the margin, or nothing can be compared.
    case addsUp
    /// No rows, and something on the disk: it may be just after a start, and the list is read again for a while
    /// (`TVDriver.waitForTitles`).
    case mayStillBeComing
    /// There is more on the disk than the list holds, and no use waiting: said under the list.
    case someAreMissing
}

/// A television's recordings as a read found them, and what they come to beside its disk.
public struct TVTitles: Sendable, Equatable {
    public var rows: [RecordedTitle]
    public var account: TVTitlesAccount

    public init(rows: [RecordedTitle], account: TVTitlesAccount) {
        self.rows = rows
        self.account = account
    }
}

/// How often a list that may still be coming is read again, and for how long at most (`TVDriver.waitForTitles`),
/// counted from when it was first read so.
public struct TVTitlesWait: Sendable, Equatable {
    public var interval: Duration
    public var limit: TimeInterval

    public init(every interval: Duration, for limit: TimeInterval) {
        self.interval = interval
        self.limit = limit
    }

    /// Every ten seconds for three minutes: a real one's list came back whole within two minutes of a restart.
    public static let afterAStart = TVTitlesWait(every: .seconds(10), for: 180)
}

/// What is asked of a television's recordings: the list with what its disk says, and what it comes to. The steps,
/// and what each says on the host's screen; what the app keeps is handed to it as the read goes through (`keep`),
/// and goes with the host, which is let go of with the link. There is no playing, a television having shown no way
/// of being paused or stopped from here.
extension TVDriver {
    /// What a television's recordings are filtered by, beside the recorder's disks: it has the one disk.
    public nonisolated static let recordsTo = "TV"
    /// The line on screen while the recordings are read: it says which device, beside the recorder's own.
    public static let titlesLine = "テレビの録画一覧を取得中"
    /// Said on the host's line for as long as a list that may still be coming is waited for.
    public nonisolated static let titlesComingLine = "テレビの録画を読み込んでいます"
    /// Said under the list when there is more on the disk than the list holds (`TVTitlesAccount.someAreMissing`).
    public nonisolated static let titlesMissing = "テレビには、ここに出ていない録画があります。テレビで一度再生すると出ることがあります"

    /// How far the disk's use may run ahead of the list's rows, in the television's MB, with nothing said: a disk
    /// with nothing on it used about 72, and a real one read 11,715 used against 11,643 listed.
    nonisolated static let titlesMarginMB = 1000

    /// What `rows` come to on `storage`: the rule, for the read and for its tests. The disk's use is its total less
    /// what is free, and the rows' its `sizeMB`. A row being recorded fills the disk while it says nought, so
    /// nothing is compared beside one, and neither is anything on a disk that has not said its sizes.
    public nonisolated static func account(of rows: [RecordedTitle], on storage: TVStorage) -> TVTitlesAccount {
        guard !rows.contains(where: \.recording), let total = storage.totalMB, let free = storage.freeMB else {
            return .addsUp
        }
        let listed = rows.reduce(0) { $0 + ($1.sizeMB ?? 0) }
        guard total - free - listed > titlesMarginMB else { return .addsUp }
        return rows.isEmpty ? .mayStillBeComing : .someAreMissing
    }

    /// Reads the recordings, as a screen does when it appears, and hands `keep` what it found. Whether they were
    /// read: when they were not, the host's line says why, and what the app holds stays. A television that cannot
    /// be asked is sent nothing and nothing is said of it, as for its reservations.
    public func titles(keep: @MainActor (TVTitles) -> Void) async -> Bool {
        guard let link, canBeAsked(on: link), let read = await readTitles(on: link, underALine: true) else {
            return false
        }
        keep(read)
        return true
    }

    /// What pulling the list down asks for: the list read now, or, when the television cannot be asked, a connect,
    /// the reader having asked for another go. What that connect reaches, the screen reads.
    public func refreshTitles(keep: @MainActor (TVTitles) -> Void) async {
        guard let link else { return }
        guard canBeAsked(on: link) else {
            await link.connect()
            return
        }
        _ = await titles(keep: keep)
    }

    /// Reads a list that may still be coming again, each `titlesWait.interval`, handing `keep` each read, until one
    /// says something else (`settled`) -- rows came, or the wait is over -- or the read cannot be made: the
    /// television let go of, not to be asked, or failing, which it says. Cancelled with the task it runs in, the
    /// screen's, in the turn that is, and nothing more is sent. Under no line of the driver's: what is under way
    /// is nothing that holds the television's buttons (`TVHost.waitingForTitles`).
    public func waitForTitles(keep: @MainActor (TVTitles) -> Void) async {
        while (try? await Task.sleep(for: titlesWait.interval)) != nil {
            guard let link, canBeAsked(on: link), let read = await readTitles(on: link, underALine: false) else {
                return
            }
            keep(read)
            guard read.account == .mayStillBeComing else { return }
        }
    }

    /// One read at a time: the tab, a pull-down and the wait come together, and whoever asks while a read is out
    /// gets its answer, with no second request sent.
    private func readTitles(on link: DeviceLink, underALine: Bool) async -> TVTitles? {
        if let titlesReading { return await titlesReading.value }
        let read = Task {
            defer { self.titlesReading = nil }
            return await self.readTitlesNow(on: link, underALine: underALine)
        }
        titlesReading = read
        return await read.value
    }

    /// The read itself, as one operation through the link (`DeviceLink.run`): the television made sure of first,
    /// the disk read and then its list, and a read that goes through clears the line of what went wrong. How it
    /// failed the link says; what that tells of the registration is kept (`note`). A check that heard something else
    /// than the television saying which it is sends nothing, as for the reservations. What comes back from a
    /// television let go of meanwhile is not handed back, nor said.
    ///
    /// A disk that is not there has no list to read: empty, with nothing to say of it. So too where it went
    /// between the two requests, 41020.
    private func readTitlesNow(on link: DeviceLink, underALine: Bool) async -> TVTitles? {
        let began = link.generation
        let read = await link.run(line: underALine ? Self.titlesLine : nil, evenIfRecent: link.checksAgain,
                                  since: began) { _ -> TVTitles? in
            if let heard = link.heardInstead { throw heard }
            guard self.canBeAsked(on: link), let client = link.client as? ScalarClient else { return nil }
            let storage = try await client.storage()
            guard !link.letGo(since: began) else { return nil }
            self.facts.storage = storage
            guard storage.mounted else { return TVTitles(rows: [], account: self.settled(.addsUp)) }
            do {
                let rows = try await client.recordings()
                return TVTitles(rows: rows, account: self.settled(Self.account(of: rows, on: storage)))
            } catch ScalarError.rpc(_, _, 41020, _) {
                self.facts.storage = TVStorage(mounted: false, freeMB: nil, totalMB: nil)
                return TVTitles(rows: [], account: self.settled(.addsUp))
            }
        }
        switch read {
        case .success(let titles):
            return titles
        case .failure(let failure):
            note(failure)
            return nil
        }
    }

    /// `account`, the time the list has been waited for taken into it: a list that may still be coming is no
    /// longer said to be once `titlesWait.limit` has gone by since it was first read so, and is short of what the
    /// disk holds from then on. Anything else puts the wait behind it. So the wait does not begin again each time
    /// the screen is opened, and goes on with what is left of it for one left and come back to. An attach starts
    /// it again (`attach`): the television may be back from a restart.
    private func settled(_ account: TVTitlesAccount, now: Date = Date()) -> TVTitlesAccount {
        guard account == .mayStillBeComing else {
            listEmptySince = nil
            return account
        }
        let since = listEmptySince ?? now
        listEmptySince = since
        return now.timeIntervalSince(since) < titlesWait.limit ? account : .someAreMissing
    }

    // MARK: - one recording

    /// The lines on screen while a recording is protected, or its protection taken off, and while one is deleted:
    /// they say which device, beside the recorder's own.
    public static let protectingTitleLine = "テレビの録画を保護中"
    public static let unprotectingTitleLine = "テレビの録画の保護を解除中"
    public static let deletingTitleLine = "テレビの録画を削除中"

    /// Said of a recording still being recorded: nothing has been measured of a write to one, and its row says
    /// nothing of it until the list is read after it ends.
    public nonisolated static let stillRecording = RecorderDriver.recordingOnTheUSBDisk

    /// Why a recording cannot be changed now, or nil when it can: it is being recorded. For the doors below and for
    /// the screens, which offer no write the door would turn away.
    public nonisolated static func whyNot(altering title: RecordedTitle) -> String? {
        title.recording ? stillRecording : nil
    }

    /// Why a recording cannot be deleted now, or nil when it can: what stands in the way of changing it, and then
    /// its protection, which the television refuses to delete past, in the sentence the screens know a protected
    /// row by. A row is as old as the list it was read in, as for the recorder: 41000 says the rest (`delete`).
    public nonisolated static func whyNot(deleting title: RecordedTitle) -> String? {
        whyNot(altering: title) ?? (title.protected ? RecorderDriver.protectedCannotBeDeleted : nil)
    }

    /// Why a run does not send a recording to be protected, or to have its protection taken off: it is being
    /// recorded, or it is already the way it should be, in the sentences a recorder's is said in.
    public nonisolated static func whyNot(protecting title: RecordedTitle, _ on: Bool) -> String? {
        whyNot(altering: title) ?? RecorderDriver.whyNot(protecting: title, on)
    }

    /// Why nothing that needs the registration can be asked now, for a door to say: the registration it wants, or
    /// that the app is not connected.
    private var whyCannotBeAsked: String {
        facts.needsPairing ? ScalarError.notRegistered.explanation : whyNotConnected
    }

    /// A write: the television refuses to delete it until this is taken off. What it came to, with its sentence,
    /// and whether the list is to be read again; `keep` is how the app's list shows it, called once the television
    /// has taken it. Turned away at the door with nothing sent and the line left, the result saying why: the link
    /// gone, a row being recorded, a television that cannot be asked. Otherwise as `written`. A recording the
    /// television no longer lists is said to be so in the result alone, and the list is to be read again.
    public func protect(_ title: RecordedTitle, _ on: Bool, keep: @MainActor () -> Void) async
        -> (altered: Altered, readAgain: Bool) {
        guard let link else { return (.notDone(Self.notConnected), false) }
        if let why = Self.whyNot(altering: title) { return (.notDone(why), false) }
        guard canBeAsked(on: link) else { return (.notDone(whyCannotBeAsked), false) }
        var readAgain = false
        let altered = await written(under: on ? Self.protectingTitleLine : Self.unprotectingTitleLine,
                                    on: link) { client in
            do {
                try await client.setDeleteProtection(uri: title.id, on)
                keep()
                return .done(saying: nil)
            } catch let error as any DeviceError where error.failure == .unknownItem {
                readAgain = true
                return .notDone(ItemCame.alreadyGone)
            }
        }
        return (altered, readAgain)
    }

    /// A write, and not one that can be undone: the recording is gone from the television's disk. What it came to,
    /// with its sentence, and whether the list is to be read again; `keep` takes the row out of the app's list,
    /// called once the television has taken it, and the disk is read again, for the free space, which cannot fail
    /// the delete. Turned away at the door as `protect` is, a protected row among it (`whyNot(deleting:)`).
    ///
    /// The television says what a recorder does not, so nothing is asked first. A recording protected there since
    /// the list was read is 41000: said in the result alone, in the sentence of a protected row, with the row left
    /// and the list to be read again, which shows it. One it no longer lists is 41001: gone already, as a recorder's
    /// 820 is, so the row is taken out and the result says that it was. Otherwise as `written`.
    public func delete(_ title: RecordedTitle, keep: @MainActor () -> Void) async
        -> (altered: Altered, readAgain: Bool) {
        guard let link else { return (.notDone(Self.notConnected), false) }
        if let why = Self.whyNot(deleting: title) { return (.notDone(why), false) }
        guard canBeAsked(on: link) else { return (.notDone(whyCannotBeAsked), false) }
        var readAgain = false
        let altered = await written(under: Self.deletingTitleLine, on: link) { client in
            do {
                try await client.deleteContent(uri: title.id)
                keep()
                await self.learnTheDisk(on: client)
                return .done(saying: nil)
            } catch ScalarError.rpc(_, _, 41000, _) {
                readAgain = true
                return .notDone(RecorderDriver.protectedCannotBeDeleted)
            } catch let error as any DeviceError where error.failure == .unknownItem {
                keep()
                return .done(saying: ItemCame.alreadyGone)
            }
        }
        return (altered, readAgain)
    }

    /// One write, written on the link's parts as a change of a reservation is (`update`): under `line`, the
    /// television made sure of first, sent on the link's client once the check has answered, and the line of what
    /// went wrong cleared by an answer. A check that said no, or heard something else than the television saying
    /// which it is, has nothing sent, and the result says what it left on the line. Silence may be a write that
    /// arrived: nothing is sent after it, the television is given up on, and the line and the result say so. Any
    /// other refusal is said in the television's words, on the line and in the result, and one for the cookie puts
    /// down that the registration is wanted. Carried through though the app lets go of the television meanwhile, as
    /// a delete of a reservation is.
    private func written(under line: String, on link: DeviceLink,
                         _ send: @MainActor (ScalarClient) async throws -> Altered) async -> Altered {
        let owner = link.owner
        return await link.underALine(line) { _ in
            guard await link.ensureUp(evenIfRecent: link.checksAgain), self.mayBeSent(on: link),
                  let client = link.client as? ScalarClient else {
                return .notDone(owner?.problem ?? self.whyNotConnected)
            }
            do {
                let altered = try await send(client)
                owner?.problem = nil
                return altered
            } catch let error as any DeviceError where error.failure == .silent {
                _ = link.say(.silentAfterSending(sentence: Self.mayHaveArrived))
                return .notDone(Self.mayHaveArrived)
            } catch is DeviceLetGo {
                // Not sent: the client was retired, as for a delete of a reservation.
                return .notDone(Self.notConnected)
            } catch {
                self.say(error, on: link)
                return .notDone((error as? any DeviceError)?.explanation ?? String(describing: error))
            }
        }
    }

    /// The disk read again, for the free space: only shown, so a television that does not say leaves it as it was
    /// and nothing that came before it is said to have failed.
    private func learnTheDisk(on client: ScalarClient) async {
        if let storage = try? await client.storage() { facts.storage = storage }
    }

    // MARK: - a run over many

    /// Begins a run, by the doors of a single write: the link gone, or a television that cannot be asked, or one a
    /// connect is under way for, whose client has yet to hear which television answers it. Nothing is asked, and
    /// nothing is said on the line.
    public func beginRun(_ kind: RunKind) -> Result<Run, RunStop> {
        guard let link else { return .failure(.said(Self.notConnected)) }
        guard canBeAsked(on: link), !link.session.connecting else { return .failure(.said(whyCannotBeAsked)) }
        return .success(Run(kind: kind, began: link.generation))
    }

    /// Whether a run may go on to a recording: nil when it may, or why it stops there with nothing sent. The
    /// television let go of since the run began, a door of a single write, or the check before it, which is made
    /// for each recording as anything else the reader asks for: a no, and a check that heard something else than
    /// the television saying which it is, stop the run with what it left on the line.
    public func mayGoOn(_ run: Run) async -> RunStop? {
        guard let link, !link.letGo(since: run.began) else { return .said(Self.notConnected) }
        guard canBeAsked(on: link) else { return .said(whyCannotBeAsked) }
        let check = await link.check(evenIfRecent: link.checksAgain)
        guard !link.letGo(since: run.began) else { return .said(Self.notConnected) }
        guard case .up = check, mayBeSent(on: link) else { return .said(link.owner?.problem ?? whyNotConnected) }
        return nil
    }

    /// Deletes one recording of a run, and says what that came to. One that cannot be deleted now is passed over
    /// with its sentence and nothing asked; for what is asked, `written(in:)`.
    public func delete(_ title: RecordedTitle, in run: Run) async -> ItemCame {
        if let why = Self.whyNot(deleting: title) { return .passedOver(why) }
        return await written(in: run) { try await $0.deleteContent(uri: title.id) }
    }

    /// Protects one recording of a run, or takes its protection off, and says what that came to, as `delete(_:in:)`.
    public func protect(_ title: RecordedTitle, _ on: Bool, in run: Run) async -> ItemCame {
        if let why = Self.whyNot(protecting: title, on) { return .passedOver(why) }
        return await written(in: run) { try await $0.setDeleteProtection(uri: title.id, on) }
    }

    /// One request of a run, on the client the link has in hand, the recording's check made (`mayGoOn`). A recording
    /// protected since the list was read is passed over in that sentence, one no longer listed is gone, and any
    /// other refusal passes it over in the television's words, said of that row alone. Silence stops the run at it:
    /// it may have arrived, the line says so and the television is given up on, and every recording after it would
    /// wait out the same timeout. A television let go of stops the run with nothing said.
    private func written(in run: Run, _ send: @MainActor (ScalarClient) async throws -> Void) async -> ItemCame {
        guard let link, !link.letGo(since: run.began), let client = link.client as? ScalarClient else {
            return .stopped(.said(Self.notConnected))
        }
        do {
            try await send(client)
            return .done
        } catch ScalarError.rpc(_, _, 41000, _) {
            return .passedOver(RecorderDriver.protectedCannotBeDeleted)
        } catch let error as any DeviceError where error.failure == .unknownItem {
            return .gone
        } catch let error as any DeviceError where error.failure == .silent {
            _ = link.say(.silentAfterSending(sentence: Self.mayHaveArrived), since: run.began)
            return .stopped(.silent(afterSending: true))
        } catch is DeviceLetGo {
            return .stopped(.said(Self.notConnected))
        } catch {
            note(OperationFailure(error, sending: nil))
            return .passedOver((error as? any DeviceError)?.explanation ?? String(describing: error))
        }
    }

    /// Ends a run: after one that deleted something and that nothing stopped, the disk is read again, for the free
    /// space, on the television it began with.
    public func end(_ run: Run, deleted: Int, stopped: RunStop?) async {
        guard deleted > 0, stopped == nil, let link, !link.letGo(since: run.began),
              let client = link.client as? ScalarClient else { return }
        await learnTheDisk(on: client)
    }
}

extension TVDriver: RunDriver {}
