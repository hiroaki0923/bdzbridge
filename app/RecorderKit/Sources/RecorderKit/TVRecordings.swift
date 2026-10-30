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
}
