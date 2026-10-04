import Foundation
@testable import RecorderKit

/// One programme a check of the sitting may reserve: what a reservation of it is made of, and nothing that
/// says what it is called or who broadcasts it.
struct TVPick: Codable, Sendable, Equatable {
    var broadcastingType: Int
    var serviceID: Int
    var eventID: Int
    var start: Date
    var durationSec: Int

    var end: Date { start.addingTimeInterval(TimeInterval(durationSec)) }
    var channel: TVPicks.Channel { TVPicks.Channel(broadcastingType: broadcastingType, serviceID: serviceID) }
}

/// The programmes the checks of a sitting choose from, written to a file from the recorder's guide before the
/// sitting: a television has no guide to choose from, and a check sends the recorder nothing. They are more
/// than any sitting uses, because whoever picks them cannot see the television's list: a check takes the
/// first of them whose slot the television has nothing in.
struct TVPicks: Codable, Sendable, Equatable {
    struct Channel: Codable, Sendable, Hashable {
        var broadcastingType: Int
        var serviceID: Int
    }

    var programmes: [TVPick] = []
    /// The stations named when the picks were written, for the check of a station that is not received and
    /// of a kind of broadcast no reservation has been sent for: which those are only the household knows.
    var named: [Channel] = []

    /// The longest programme that is picked. What a television makes of a longer reservation has not been
    /// seen, and is not what a sitting is for.
    static let longest = 4 * 3600
}

extension TVPicks.Channel {
    /// `<kind>:<service id>`, the kind as `Codes.broadcasting` names it: `cs:1601`. Nil for anything else.
    init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let type = Codes.broadcasting[String(parts[0])], let serviceID = Int(parts[1]) else {
            return nil
        }
        self.init(broadcastingType: type, serviceID: serviceID)
    }
}

extension TVPicks {
    /// Picked from a recorder's guide, given by kind of broadcast: every terrestrial programme that starts
    /// after `now`, and those of the stations named, whatever their kind. A subchannel's reference to its
    /// parent's programme is no programme to reserve, and is left out.
    init(guide: [String: [GuideService]], named: [Channel] = [], after now: Date) {
        var programmes: [TVPick] = []
        for (kind, services) in guide {
            guard let type = Codes.broadcasting[kind] else { continue }
            for service in services {
                let channel = Channel(broadcastingType: type, serviceID: service.serviceID)
                guard kind == "td" || named.contains(channel) else { continue }
                programmes += service.programs
                    .filter { !$0.isReference && $0.start > now && (1...Self.longest).contains($0.durationSec) }
                    .map { TVPick(broadcastingType: type, serviceID: service.serviceID, eventID: $0.eventID,
                                  start: $0.start, durationSec: $0.durationSec) }
            }
        }
        self.init(programmes: programmes.sorted { ($0.start, $0.serviceID) < ($1.start, $1.serviceID) },
                  named: named)
    }

    static func read(_ file: URL) throws -> TVPicks { try TVFile.read(TVPicks.self, from: file) }
    func write(to file: URL) throws { try TVFile.write(self, to: file) }
}

/// What a sitting has made on the television, kept in a file outside the repository so that it outlives a
/// check that is killed half way. What is about to be made is written here before its create is sent --
/// the channel, the programme, the start, the length and the repeat, and no title -- and struck out once the
/// television's list has shown that nothing of it is there. An entry is never taken out: what the list is
/// held against at the end is everything the sitting ever sent.
struct TVLedger: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var broadcastingType: Int
        var serviceID: Int
        var eventID: Int
        var start: Date
        var durationSec: Int
        var repeatType: String
        var struck = false

        /// Whether `row` is a recording this entry may have left behind: on its channel, for its programme,
        /// and at its start -- or with its repeat, a television being free to list a repeat at another of
        /// its starts. Not the programme alone: the household may hold a reservation of its own for it.
        func mayHaveLeft(_ row: TVScheduleRow) -> Bool {
            guard row.type == "recording", row.eventId == String(eventID),
                  let channel = TVScheduleRow.channel(of: row.uri), channel.broadcastingType == broadcastingType,
                  channel.serviceID == serviceID else { return false }
            return RecorderTime.parse(row.startDateTime) == start || (repeatType != "1" && row.repeatType == repeatType)
        }
    }

    /// How a list counts: its rows, the recordings among them, and the rows that lose to another.
    struct Counts: Codable, Equatable {
        var rows: Int
        var recordings: Int
        var overlapped: Int

        var said: String { "rows \(rows), recordings \(recordings), losing to another \(overlapped)" }
    }

    var entries: [Entry] = []
    /// The television's list as it counted before the first create of the sitting, the household's viewing
    /// reservation for the sitting in it: what the list is to count as again when everything is taken off.
    var before: Counts?

    var open: Int { entries.filter { !$0.struck }.count }
}

extension TVLedger.Counts {
    init(_ listed: [TVScheduleRow]) {
        self.init(rows: listed.count, recordings: listed.filter { $0.type == "recording" }.count,
                  overlapped: listed.filter { $0.overlapStatus.map { $0 != "notOverlapped" } == true }.count)
    }
}

extension TVLedger {
    /// A file that is not there yet is a ledger with nothing in it. One that cannot be read throws: taken
    /// for empty, it would say that nothing was ever made.
    static func read(_ file: URL) throws -> TVLedger {
        guard FileManager.default.fileExists(atPath: file.path) else { return TVLedger() }
        return try TVFile.read(TVLedger.self, from: file)
    }

    func write(to file: URL) throws { try TVFile.write(self, to: file) }
}

/// The two files of a sitting, as JSON a person can read and strike an entry out of by hand.
enum TVFile {
    static func read<T: Decodable>(_ type: T.Type, from file: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: file))
    }

    static func write<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: [.atomic])
    }
}

/// The checks with which the requests that make a reservation on a television meet a real one, the owner
/// watching: each a function here, run against the real television by `LiveTVTests` and, before that, against
/// the invented one by `TVSittingTests`, in the same order and by the same code.
///
/// A mistake in a check leaves a reservation on somebody's television, or deletes one of theirs. So:
///
/// - **Nothing is made unless the sitting may write**, and the television says it is `active`: the sitting
///   is held with it on. Nor while the ledger holds an entry not struck out: something of an earlier check
///   may still be there.
/// - **What a check deletes is only what it made.** The list is read before each create, and the recordings
///   whose ids are new in the list read after it are the check's own: a television's ids only grow. Exactly
///   those rows are deleted, each as it was last read, and the list is read again to see them gone. Nothing
///   is ever deleted by its programme, its time or its title.
/// - **The ledger** is written before a create is sent and struck out after the list shows nothing of it. A
///   check that fails on the way takes off what it made before it ends, and says what it could not.
/// - **After silence on a create nothing is sent again.** The list is read, once; a row of the check's own
///   found there is deleted, and the check ends.
/// - **A slot is empty before anything is put in it** (`isFree`): twenty hours or more ahead, and nothing of
///   the television's list within three hours either side.
/// - **No create is sent that the television says would stop a reservation** that is not the check's own.
/// - **Each request is sent once.** Nothing here asks again.
/// - **What is said** is counts, statuses, error codes, field names, weekdays, times of day and the repeat
///   read back: never a title, a station's name, an id of the television's, an address or a cookie. That
///   holds for what a check throws as well, so an error is said by its kind (`said`) and never as it came.
actor TVSitting {
    /// The title every reservation of a sitting is made under. No programme's: the picks carry none, and one
    /// left behind is known by it on the television's own list for what it is. The half-width space in it is
    /// one a television writes back full-width, so a check that found its rows by title would lose them.
    static let title = "BD Bridge 確認"
    /// How far ahead a programme has to be before a reservation of it is made.
    static let ahead: TimeInterval = 20 * 3600
    /// How far either side of a reservation the television's list has to be empty.
    static let margin: TimeInterval = 3 * 3600
    /// The kinds of broadcast a television lists stations of, in the order they are asked for.
    static let kinds = ["td", "bs", "cs", "bs4k", "cs4k"]
    private static let terrestrial = Codes.broadcasting["td"] ?? 2

    /// Why a check did not run. Nothing was made.
    struct Refused: Error, Equatable {
        var why: String
    }

    /// What ended a check on the way, or what it found that it is not to find: said after everything that
    /// could be taken off was.
    struct Stopped: Error, Equatable {
        var what: String
    }

    private let client: ScalarClient
    private let picks: TVPicks
    private let ledgerFile: URL
    private let mayWrite: Bool
    private let look: TimeInterval
    private let now: @Sendable () -> Date
    private let say: @Sendable (String) -> Void

    /// What the check under way has made and not yet seen gone: each row as it was last read, and the
    /// ledger's entry it was made for.
    private var mine: [(row: TVScheduleRow, entry: Int)] = []
    /// The television's list as the check under way first read it, and as it last did.
    private var found: [TVScheduleRow]?
    private var last: [TVScheduleRow]?

    /// `look` is how long a reservation with a repeat is left on the television for the owner to read how
    /// its own list words it. `now` and `say` are the clock and the terminal, which a rehearsal replaces.
    init(client: ScalarClient, picks: TVPicks, ledger: URL, mayWrite: Bool, look: TimeInterval = 0,
         now: @escaping @Sendable () -> Date = { Date() }, say: @escaping @Sendable (String) -> Void) {
        self.client = client
        self.picks = picks
        ledgerFile = ledger
        self.mayWrite = mayWrite
        self.look = look
        self.now = now
        self.say = say
    }

    // MARK: - the checks, in the order they are run

    /// The stations, as the app asks for them: each kind of broadcast, page after page, and then one page
    /// past the end of the first kind that has any, which is what says how a list ends whose last page is
    /// full. A kind that is answered with an error is said and the others are still asked: not every
    /// television has all five. Makes nothing, and a television answers it in standby as well.
    func theStations() async throws {
        var read: [Int: [TVStation]] = [:]
        for kind in Self.kinds {
            guard let type = Codes.broadcasting[kind] else { continue }
            do {
                let stations = try await client.stations(of: type)
                read[type] = stations
                say("stations of \(kind): \(stations.count)")
            } catch {
                say("stations of \(kind): \(Self.said(error))")
            }
        }
        let channels = Set(picks.programmes.map(\.channel))
        let missing = channels.filter { channel in
            read[channel.broadcastingType]?.contains { $0.serviceID == channel.serviceID } != true
        }
        say("channels among the picks with no station on the television: \(missing.count) of \(channels.count)")

        let kind = Self.kinds.first { kind in Codes.broadcasting[kind].flatMap { read[$0] }?.isEmpty == false }
        guard let kind, let type = Codes.broadcasting[kind], let count = read[type]?.count else {
            throw Stopped(what: "no kind of broadcast has a station to ask a page past the end of")
        }
        do {
            let page = try await client.stationPage(of: type, from: count)
            say("rows in a page past the end of \(kind): \(page.rows)")
        } catch {
            say("a page past the end of \(kind): \(Self.said(error))")
        }
    }

    /// The eight requests of a whole write, in the order the app is to send them for one waiting row: the
    /// disk, the list, the stations, the question, the create, the list -- and then the delete of the row
    /// just read, and the list. The row read back is held against what was sent.
    func aWholeWrite() async throws {
        try await making {
            let disk = try await ask("getStorageList") { try await client.storage() }
            say("the disk: \(disk.mounted ? "mounted" : "not mounted")")
            guard disk.mounted else { throw Refused(why: "the television has no disk to record to") }
            let listed = try await list()
            say("the list: \(TVLedger.Counts(listed).said)")
            let (pick, station) = try choose(on: try await stations(of: Self.terrestrial), in: listed)
            let body = try body(pick, on: station)
            try await nothingNamed(by: body, but: nil)
            let created = try await create(body, of: pick)
            say("the create: \(created.answer); rows made: \(created.rows.count)")
            for row in created.rows { say("the row read back: \(Self.held(row, against: body))") }
            try await takeOff()
            guard created.taken, created.rows.count == 1 else { throw Stopped(what: "the create did not make one row") }
        }
    }

    /// A recording of the programme the household has a viewing reservation for: the question, the create,
    /// the list, the delete of the recording. Whether a viewing reservation stops the create, is named by
    /// the question, or is answered as the same programme a second time, is what it is run to see. The
    /// viewing reservation is the newest the television lists (`theReminder`), and is left as it was.
    func aRecordingWhereAViewingReservationIs() async throws {
        try await making {
            let listed = try await list()
            let (reminder, pick) = try theReminder(in: listed)
            let stations = try await stations(of: pick.broadcastingType)
            guard let station = stations.first(where: { $0.serviceID == pick.serviceID }) else {
                throw Refused(why: "the television lists no station for the viewing reservation's channel")
            }
            let others = listed.filter { $0.id != reminder.id }
            guard Self.isFree(from: pick.start, to: pick.end, in: others, everyDay: false, now: now()) else {
                throw Refused(why: "the viewing reservation is less than twenty hours ahead, or something else"
                              + " is listed within three hours of it")
            }
            say("the viewing reservation: \(Self.when(reminder)); its uri is the station's own: "
                + (reminder.uri.utf8.elementsEqual(station.uri.utf8) ? "yes" : "no"))
            let body = try body(pick, on: station)
            say("rows of the programme before: \(Self.types(of: pick, in: listed))")
            try await nothingNamed(by: body, but: reminder)
            let created = try await create(body, of: pick)
            say("the create: \(created.answer); rows made: \(created.rows.count)")
            say("rows of the programme after: \(Self.types(of: pick, in: last ?? []))")
            try await takeOff()
        }
    }

    /// The same programme twice: the second create is to be answered as a reservation already there, and to
    /// make nothing, so that one row is what is deleted.
    func theSameProgrammeTwice() async throws {
        try await making {
            let listed = try await list()
            let (pick, station) = try choose(on: try await stations(of: Self.terrestrial), in: listed)
            let body = try body(pick, on: station)
            let first = try await create(body, of: pick)
            say("the first create: \(first.answer); rows made: \(first.rows.count)")
            guard first.taken, first.rows.count == 1 else { throw Stopped(what: "the first did not make one row") }
            let second = try await create(body, of: pick)
            let read = (second.failure as? ScalarError)?.failure == .alreadyThere
            say("the second: \(second.answer), read as already there: \(read ? "yes" : "no");"
                + " rows made: \(second.rows.count)")
            try await takeOff()
            guard read, second.rows.isEmpty else {
                throw Stopped(what: "the same programme a second time was not answered as already there")
            }
        }
    }

    /// The repeats, one at a time, on one programme: its own weekday, by its name, daily, Monday to Friday,
    /// Monday to Saturday -- and then the next weekday's code, which the app never sends and which is the
    /// one test there is of which weekday a code means. Each is made, read back, left for the owner to read
    /// on the television's own list, and deleted before the next. The programme is one every one of the five
    /// is sent for, a weekday's from four in the morning, at a time of day nothing is listed at on any day.
    func theRepeats() async throws {
        try await making {
            let listed = try await list()
            let stations = try await stations(of: Self.terrestrial)
            let (pick, station) = try choose(on: stations, in: listed, everyDay: true) {
                TVReservationBody.repeatType(for: "w15", start: $0.start) != nil
            }
            let own = (1...7).first { TVReservationBody.repeatType(for: "w\($0)", start: pick.start) != nil }
            guard let own else { throw Refused(why: "the programme chosen has no weekday code") }
            say("the programme: \(Self.when(pick.start))")
            var bodies = try ["w\(own)", "S001", "d", "w15", "w16"].map { try body(pick, on: station, repeating: $0) }
            var next = bodies[0]
            next.repeatType = "w\(own % 7 + 1)"
            bodies.append(next)
            for (round, body) in bodies.enumerated() {
                let created = try await create(body, of: pick)
                say("round \(round + 1), \(body.repeatType) sent: \(created.answer); rows made: \(created.rows.count)")
                for row in created.rows {
                    say("  read back: repeatType \(row.repeatType ?? "none"), start \(Self.when(row))")
                }
                if !created.rows.isEmpty, look > 0 {
                    say("  on the television's own list for \(Int(look)) seconds: how is its repeat worded?")
                    try await Task.sleep(nanoseconds: UInt64(look * 1_000_000_000))
                }
                try await takeOff()
            }
        }
    }

    /// Three at once, twice. First as it was measured by script: two at one time on two stations, and a
    /// third on a third station that starts later and overlaps them in part, in an empty slot. Then with the
    /// third starting before the two, beside the household's viewing reservation, which is on a station of
    /// its own inside the slot: whether the new row can be the one that loses, and whether the question can
    /// name a viewing reservation when both tuners are taken. Both arrangements are found before anything is
    /// made. The third is made only when every row the question names is the check's own.
    func threeAtOnce() async throws {
        try await making {
            let listed = try await list()
            let stations = try await stations(of: Self.terrestrial)
            guard let reminder = Self.newestReminder(in: listed) else {
                throw Refused(why: "no viewing reservation is listed to put the second arrangement beside")
            }
            guard let later = three(startingLater: true, beside: nil, on: stations, in: listed) else {
                throw Refused(why: "no three programmes among the picks, the third starting later, are in an"
                              + " empty slot")
            }
            guard let earlier = three(startingLater: false, beside: reminder, on: stations, in: listed) else {
                throw Refused(why: "no three programmes among the picks, the third starting earlier, are beside"
                              + " the viewing reservation with nothing else within three hours")
            }
            try await arrange("the third later", later, beside: nil)
            try await arrange("the third earlier", earlier, beside: reminder)
        }
    }

    /// A create with the registered client id and a cookie the television never gave, sent by `stranger`,
    /// and the list read with the good one: that a create refused for its cookie made nothing, which is what
    /// lets the app send it again once with a newer cookie.
    func aCreateWithACookieNotTaken(sentBy stranger: ScalarClient) async throws {
        try await making {
            let listed = try await list()
            let (pick, station) = try choose(on: try await stations(of: Self.terrestrial), in: listed)
            let created = try await create(try body(pick, on: station), of: pick, by: stranger)
            say("the create with a cookie the television never gave: \(created.answer);"
                + " rows made: \(created.rows.count)")
            try await takeOff()
            guard case .http(403, _)? = created.failure as? ScalarError, created.rows.isEmpty else {
                throw Stopped(what: "a create with a cookie the television never gave was not refused for it")
            }
        }
    }

    /// One create on each station named when the picks were written -- a station the television lists and
    /// does not receive, a station of a kind no reservation has been sent for -- and its delete where a row
    /// was made. The code a television answers a station it cannot show with, if it has one, is what the app
    /// is to hold such a row for. A station the television does not list is sent nothing.
    func theStationsNamed() async throws {
        try await making {
            guard !picks.named.isEmpty else { throw Refused(why: "no station was named when the picks were written") }
            let listed = try await list()
            var read: [Int: [TVStation]] = [:]
            var unread: Set<Int> = []
            for (index, channel) in picks.named.enumerated() {
                let kind = Codes.broadcasting(code: channel.broadcastingType) ?? "an unknown kind"
                let name = "station \(index + 1) of \(picks.named.count) (\(kind))"
                if read[channel.broadcastingType] == nil, !unread.contains(channel.broadcastingType) {
                    do {
                        read[channel.broadcastingType] = try await client.stations(of: channel.broadcastingType)
                    } catch {
                        unread.insert(channel.broadcastingType)
                        say("\(name): the stations of its kind: \(Self.said(error))")
                    }
                }
                guard let stations = read[channel.broadcastingType] else { continue }
                guard stations.contains(where: { $0.serviceID == channel.serviceID }) else {
                    say("\(name): not in the television's list, so nothing is sent")
                    continue
                }
                let chosen = try? choose(on: stations, in: last ?? listed) { $0.channel == channel }
                guard let (pick, station) = chosen else {
                    say("\(name): none of its programmes among the picks is in an empty slot")
                    continue
                }
                let body = try body(pick, on: station)
                let created = try await create(body, of: pick)
                say("\(name): \(created.answer); rows made: \(created.rows.count)")
                for row in created.rows { say("  the row read back: \(Self.held(row, against: body))") }
                try await takeOff()
            }
        }
    }

    /// The count afterwards. Fails unless the ledger has every entry struck out, the list holds no
    /// recording an entry may have left behind -- a struck one as well: a create that met silence may be
    /// carried out after the list was read -- and the list counts as it did before the first create.
    func whatIsLeft() async throws {
        let listed = try await ask("getScheduleList") { try await client.schedules() }
        let ledger = try ledger()
        let counts = TVLedger.Counts(listed)
        let left = listed.filter { row in ledger.entries.contains { $0.mayHaveLeft(row) } }
        say("the list: \(counts.said); before the first create: \(ledger.before?.said ?? "not written down")")
        say("the ledger: entries \(ledger.entries.count), not struck out \(ledger.open);"
            + " recordings listed that one of them may have left: \(left.count)")
        var wrong: [String] = []
        if ledger.open > 0 { wrong.append("entries of the ledger not struck out: \(ledger.open)") }
        if !left.isEmpty { wrong.append("recordings listed that may be the sitting's: \(left.count)") }
        if let before = ledger.before, before != counts { wrong.append("the list does not count as it did") }
        guard wrong.isEmpty else { throw Stopped(what: wrong.joined(separator: "; ")) }
    }

    // MARK: - what every check that makes something is made of

    /// A check that makes something: behind the guard, and with what it made taken off again however it
    /// ends. A check that fails on the way does not leave what it had made by then, and what could not be
    /// taken off is said with what failed. Afterwards the list is to read as it did before the check began.
    private func making(_ check: () async throws -> Void) async throws {
        (mine, found, last) = ([], nil, nil)
        try await mayMake()
        var failure: (any Error)?
        do { try await check() } catch { failure = error }
        var wrong: String?
        do { try await takeOff() } catch { wrong = Self.told(error) }
        if wrong == nil, let found, let last, found != last {
            let changed = found.filter { !last.contains($0) }.count
            wrong = "the list does not read as it did before the check: rows then \(found.count), now"
                + " \(last.count), of those gone or read otherwise \(changed)"
        }
        switch (failure, wrong) {
        case (nil, nil): say("the television's list reads as it did before the check")
        case (let failure?, nil): throw failure
        case (nil, let wrong?): throw Stopped(what: wrong)
        case (let failure?, let wrong?): throw Stopped(what: "\(Self.told(failure)); and \(wrong)")
        }
    }

    /// The guard, in the order that sends least: with no leave to write nothing is sent at all, and the
    /// ledger is not so much as read.
    private func mayMake() async throws {
        guard mayWrite else { throw Refused(why: "writing to the television was not asked for") }
        let open = try ledger().open
        guard open == 0 else {
            throw Refused(why: "entries of the ledger not struck out: \(open). See on the television's own list that"
                          + " nothing of them is there, and strike them out, before anything more is made")
        }
        let power = try await ask("getPowerStatus") { try await client.powerStatus() }
        guard power == "active" else {
            throw Refused(why: "the television says it is \(power), and this is a check for one that is on")
        }
    }

    /// One request, sent once. What goes wrong is thrown by its kind and its code alone: an error as it
    /// comes can carry the address it was sent to.
    private func ask<T: Sendable>(_ method: String, _ request: () async throws -> T) async throws -> T {
        do { return try await request() } catch { throw Stopped(what: "\(method): \(Self.said(error))") }
    }

    /// The television's list, read once, and kept as the last read: of the list, and of each row the check
    /// has made, which is deleted as it was last read.
    @discardableResult
    private func list() async throws -> [TVScheduleRow] {
        let rows = try await ask("getScheduleList") { try await client.schedules() }
        mine = mine.map { held in (rows.first { $0.id == held.row.id } ?? held.row, held.entry) }
        if found == nil { found = rows }
        last = rows
        return rows
    }

    private func stations(of broadcastingType: Int) async throws -> [TVStation] {
        try await ask("getContentList") { try await client.stations(of: broadcastingType) }
    }

    /// What a create came to: the error it was answered with, or none when it was taken, and the rows the
    /// list shows it made.
    private struct Created {
        var failure: (any Error)?
        var rows: [TVScheduleRow]

        var taken: Bool { failure == nil }
        var answer: String { failure.map(TVSitting.said) ?? "taken" }
    }

    /// One create, sent once, by `sender` or by the sitting's own client: the ledger first, then the
    /// request, then the list, whatever the answer and after none. The recordings whose ids the list read
    /// before the create did not have are the check's own from here on. An entry whose create was not taken
    /// and made nothing is struck out at once; one whose create was taken and shows nothing in the list is
    /// left open, and the check ends: something may be there that the list did not show. After silence the
    /// check ends as well: nothing is sent again, and what the list showed of it is taken off as it ends.
    private func create(_ body: TVReservationBody, of pick: TVPick,
                        by sender: ScalarClient? = nil) async throws -> Created {
        var listed = last
        if listed == nil { listed = try await list() }
        let before = Set((listed ?? []).map(\.id))
        let entry = try note(pick, repeating: body.repeatType)
        var failure: (any Error)?
        do { try await (sender ?? client).addSchedule(body) } catch { failure = error }
        let after: [TVScheduleRow]
        do {
            after = try await list()
        } catch {
            throw Stopped(what: "\(Self.told(error)) after a create (\(failure.map(Self.said) ?? "taken")):"
                          + " what it made is not known, and its entry is left in the ledger")
        }
        let rows = after.filter { $0.type == "recording" && !before.contains($0.id) }
        mine += rows.map { ($0, entry) }
        if rows.isEmpty {
            guard failure != nil else {
                throw Stopped(what: "a create was taken and the list shows nothing new: its entry is left in the"
                              + " ledger")
            }
            try strike(entry)
        }
        if (failure as? ScalarError)?.failure == .silent {
            throw Stopped(what: "a create met no answer, and nothing is sent again; rows it made: \(rows.count)")
        }
        return Created(failure: failure, rows: rows)
    }

    /// Takes off what the check has made and not yet seen gone: each row as it was last read, each delete
    /// sent once, and then the list, read once, to see them gone. An entry whose rows are all gone is struck
    /// out. What is still listed stays in the ledger and is thrown; nothing is tried a second time.
    private func takeOff() async throws {
        let taking = mine
        mine = []
        guard !taking.isEmpty else { return }
        for held in taking {
            do { try await client.deleteSchedule(held.row) } catch { say("  a delete: \(Self.said(error))") }
        }
        let after: [TVScheduleRow]
        do {
            after = try await list()
        } catch {
            throw Stopped(what: "\(Self.told(error)) after the deletes: whether they took is not known,"
                          + " and their entries are left in the ledger")
        }
        let left = taking.filter { held in after.contains { $0.id == held.row.id } }
        for entry in Set(taking.map(\.entry)) where !left.contains(where: { $0.entry == entry }) { try strike(entry) }
        guard left.isEmpty else {
            throw Stopped(what: "rows the check made that are still listed after their delete: \(left.count);"
                          + " they are left in the ledger")
        }
    }

    /// Asks what a reservation would stop from recording, and refuses to go on when the answer names
    /// anything but `reminder`: the create would cost the household a reservation of its own.
    private func nothingNamed(by body: TVReservationBody, but reminder: TVScheduleRow?) async throws {
        let named = try await ask("getConflictScheduleList") { try await client.wouldPushOut(body) }
        var said = "rows the question names: \(named.count)"
        if !named.isEmpty { said += ", of type \(named.map(\.type).joined(separator: ", "))" }
        if let reminder {
            let among = named.contains { $0.id == reminder.id }
            said += "; the viewing reservation among them: \(among ? "yes" : "no")"
        }
        say(said)
        guard named.allSatisfy({ $0.id == reminder?.id }) else {
            throw Refused(why: "the television says the reservation would stop one that is not the check's own")
        }
    }

    /// Two creates at one time and the question for a third, which is made when every row the question
    /// names is one of the two; then what each of them reads as, and all of them taken off.
    private func arrange(_ name: String, _ three: Three, beside reminder: TVScheduleRow?) async throws {
        var roles: [String: String] = [:]
        for (role, programme) in [("the first", three.a), ("the second", three.b)] {
            let created = try await create(try body(programme.pick, on: programme.station), of: programme.pick)
            say("\(name), \(role): \(created.answer); rows made: \(created.rows.count)")
            guard created.taken, created.rows.count == 1 else { throw Stopped(what: "\(role) did not make one row") }
            roles[created.rows[0].id] = role
        }
        let third = try body(three.c.pick, on: three.c.station)
        let named = try await ask("getConflictScheduleList") { try await client.wouldPushOut(third) }
        let who = named.map { row in
            roles[row.id] ?? (row.id == reminder?.id ? "the viewing reservation" : "another \(row.type)")
        }
        say("\(name), rows the question for the third names: \(named.count)"
            + (who.isEmpty ? "" : " (\(who.joined(separator: ", ")))"))
        if named.allSatisfy({ roles[$0.id] != nil }) {
            let created = try await create(third, of: three.c.pick)
            say("\(name), the third: \(created.answer); rows made: \(created.rows.count)")
            for row in created.rows { roles[row.id] = "the third" }
        } else {
            say("\(name): a row that is not the check's own is named, so the third is not made")
        }
        let reads = (last ?? []).compactMap { row -> String? in
            let role = roles[row.id] ?? (row.id == reminder?.id ? "the viewing reservation" : nil)
            return role.map { "\($0) \(row.overlapStatus ?? "with no overlap status")" }
        }
        say("\(name), with them in place: \(reads.sorted().joined(separator: ", "))")
        try await takeOff()
    }

    // MARK: - what is chosen, and what is said

    /// A reservation of `pick` on `station` as the app writes one, under the sitting's title.
    private func body(_ pick: TVPick, on station: TVStation, repeating code: String = "1") throws -> TVReservationBody {
        let request = ReservationRequest(title: Self.title, start: pick.start, durationSec: pick.durationSec,
                                         repeatCode: code, broadcastingType: pick.broadcastingType,
                                         serviceID: pick.serviceID, qualityCode: Codes.quality["DR"] ?? 100,
                                         eventID: pick.eventID)
        guard let body = TVReservationBody(request, on: station) else {
            throw Refused(why: "the repeat \(code) is not one a television is sent for the programme chosen")
        }
        return body
    }

    /// The first programme among the picks, by its start, that suits, has a station among `stations` and a
    /// slot the television has nothing in.
    private func choose(on stations: [TVStation], in listed: [TVScheduleRow], everyDay: Bool = false,
                        where suits: (TVPick) -> Bool = { _ in true }) throws -> (TVPick, TVStation) {
        let at = now()
        let inOrder = picks.programmes.sorted { ($0.start, $0.serviceID) < ($1.start, $1.serviceID) }
        for pick in inOrder where suits(pick) {
            let station = stations.first {
                $0.broadcastingType == pick.broadcastingType && $0.serviceID == pick.serviceID
            }
            guard let station,
                  Self.isFree(from: pick.start, to: pick.end, in: listed, everyDay: everyDay, now: at) else { continue }
            return (pick, station)
        }
        throw Refused(why: "no programme among the picks has a station on the television and an empty slot")
    }

    /// The viewing reservation a check is about, and its programme among the picks: the newest the
    /// television lists, which is the one the owner has just set.
    private func theReminder(in listed: [TVScheduleRow]) throws -> (TVScheduleRow, TVPick) {
        guard let reminder = Self.newestReminder(in: listed) else {
            throw Refused(why: "no viewing reservation is listed: set one with the remote first")
        }
        let pick = picks.programmes.first { pick in
            TVScheduleRow.channel(of: reminder.uri).map { $0 == (pick.broadcastingType, pick.serviceID) } == true
                && reminder.eventId == String(pick.eventID)
        }
        guard let pick else { throw Refused(why: "the viewing reservation's programme is not among the picks") }
        return (reminder, pick)
    }

    private struct Three {
        var a, b, c: (pick: TVPick, station: TVStation)
    }

    /// Three terrestrial programmes on three stations: two that start together, and a third that overlaps
    /// them in part, starting later than the two or earlier. The first such by the start of the two, whose
    /// slot -- from the first start to the last end -- is empty. Beside `reminder`: both of the two overlap
    /// it, none of the three is on its station, and the slot is empty but for it.
    private func three(startingLater: Bool, beside reminder: TVScheduleRow?, on stations: [TVStation],
                       in listed: [TVScheduleRow]) -> Three? {
        let at = now()
        let others = listed.filter { $0.id != reminder?.id }
        let apart = reminder.flatMap { TVScheduleRow.channel(of: $0.uri) }?.serviceID
        let span = reminder.flatMap { row in
            RecorderTime.parse(row.startDateTime).map { ($0, $0.addingTimeInterval(TimeInterval(row.durationSec))) }
        }
        let programmes = picks.programmes.compactMap { pick -> (pick: TVPick, station: TVStation)? in
            guard pick.broadcastingType == Self.terrestrial, pick.serviceID != apart else { return nil }
            return stations.first { $0.serviceID == pick.serviceID }.map { (pick, $0) }
        }.sorted { ($0.pick.start, $0.pick.serviceID) < ($1.pick.start, $1.pick.serviceID) }
        func beside(_ pick: TVPick) -> Bool { span.map { pick.start < $0.1 && pick.end > $0.0 } ?? true }

        for (index, a) in programmes.enumerated() where beside(a.pick) {
            for b in programmes[(index + 1)...] {
                guard b.pick.start == a.pick.start else { break }
                guard b.pick.serviceID != a.pick.serviceID, beside(b.pick) else { continue }
                let c = programmes.first { c in
                    guard c.pick.serviceID != a.pick.serviceID, c.pick.serviceID != b.pick.serviceID,
                          startingLater
                            ? a.pick.start < c.pick.start && c.pick.start < min(a.pick.end, b.pick.end)
                            : c.pick.start < a.pick.start && a.pick.start < c.pick.end else { return false }
                    let from = min(a.pick.start, c.pick.start), to = max(a.pick.end, b.pick.end, c.pick.end)
                    return Self.isFree(from: from, to: to, in: others, everyDay: false, now: at)
                }
                if let c { return Three(a: a, b: b, c: c) }
            }
        }
        return nil
    }

    /// Whether a reservation from `start` to `end` would have the television's list to itself: twenty hours
    /// or more ahead of `now`, and no row of `listed` within three hours either side of it. `everyDay` for
    /// a repeat: no row at that time of day, on whatever day it is listed. A listed row that repeats is held
    /// to stand at its time of day on every day whichever is asked: the list shows one start of it.
    static func isFree(from start: Date, to end: Date, in listed: [TVScheduleRow], everyDay: Bool, now: Date) -> Bool {
        guard start >= now.addingTimeInterval(ahead) else { return false }
        let from = start.addingTimeInterval(-margin), length = end.timeIntervalSince(start) + 2 * margin
        return listed.allSatisfy { row in
            guard let begins = RecorderTime.parse(row.startDateTime) else { return false }
            let offset = begins.timeIntervalSince(from), lasts = TimeInterval(max(row.durationSec, 1))
            guard everyDay || row.repeatType != "1" else { return offset >= length || offset + lasts <= 0 }
            let day: TimeInterval = 86_400
            let intoTheDay = offset - (offset / day).rounded(.down) * day
            return intoTheDay >= length && intoTheDay + lasts <= day
        }
    }

    /// The newest viewing reservation in a list, by the number in its id.
    static func newestReminder(in listed: [TVScheduleRow]) -> TVScheduleRow? {
        func number(_ row: TVScheduleRow) -> Int { row.id.split(separator: ".").last.flatMap { Int($0) } ?? 0 }
        return listed.filter { $0.type == "reminder" }.max { number($0) < number($1) }
    }

    /// The fields of a row that was made, each held against what was sent: by their names, never their
    /// values. The uri byte for byte, the start as text.
    private static func held(_ row: TVScheduleRow, against body: TVReservationBody) -> String {
        let fields: [(String, Bool)] = [
            ("uri", row.uri.utf8.elementsEqual(body.uri.utf8)),
            ("startDateTime", row.startDateTime == body.startDateTime),
            ("durationSec", row.durationSec == body.durationSec), ("eventId", row.eventId == body.eventId),
            ("repeatType", row.repeatType == body.repeatType), ("type", row.type == "recording"),
            ("quality", row.quality == "DR"),
        ]
        let other = fields.filter { !$0.1 }.map(\.0)
        return other.isEmpty ? "every field as sent, in DR" : "not as sent: \(other.joined(separator: ", "))"
    }

    /// How many rows of each type a list has for a programme on its channel.
    private static func types(of pick: TVPick, in listed: [TVScheduleRow]) -> String {
        let rows = listed.filter { row in
            row.eventId == String(pick.eventID)
                && TVScheduleRow.channel(of: row.uri).map { $0 == (pick.broadcastingType, pick.serviceID) } == true
        }
        let counted = Dictionary(grouping: rows, by: \.type).map { "\($0.value.count) \($0.key)" }.sorted()
        return counted.isEmpty ? "none" : counted.joined(separator: ", ")
    }

    /// A weekday and a time of day, in Japan: all of a start that is said.
    static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = RecorderTime.timeZone
        formatter.dateFormat = "EEEE HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func when(_ row: TVScheduleRow) -> String {
        RecorderTime.parse(row.startDateTime).map(when) ?? "a start that is no time"
    }

    /// An error by its kind and its code: what the television answered, and nothing of where it is.
    static func said(_ error: any Error) -> String {
        switch error as? ScalarError {
        case .transport: "no answer"
        case .badAddress: "an address nothing can be sent to"
        case .http(let status, _): "HTTP \(status)"
        case .rpc(_, _, let code, _): "error \(code)"
        case .unreadable: "an answer that cannot be read"
        case .notATelevision: "not a television"
        case .notRegistered: "nothing registered to send it with"
        case nil: "an error that is not the television's"
        }
    }

    /// What a check threw, in the words it was thrown with.
    private static func told(_ error: any Error) -> String {
        (error as? Refused)?.why ?? (error as? Stopped)?.what ?? said(error)
    }

    // MARK: - the ledger

    private func ledger() throws -> TVLedger {
        do { return try TVLedger.read(ledgerFile) } catch { throw Stopped(what: "the ledger cannot be read") }
    }

    private func change<T>(_ change: (inout TVLedger) -> T) throws -> T {
        var ledger = try ledger()
        let result = change(&ledger)
        do { try ledger.write(to: ledgerFile) } catch { throw Stopped(what: "the ledger cannot be written") }
        return result
    }

    /// Writes down what is about to be made, before it is sent: a ledger that cannot be written ends the
    /// check with nothing sent. The first entry of a sitting has the list's counts written beside it.
    private func note(_ pick: TVPick, repeating repeatType: String) throws -> Int {
        let counts = last.map { TVLedger.Counts($0) }
        return try change { ledger in
            if ledger.before == nil { ledger.before = counts }
            ledger.entries.append(TVLedger.Entry(broadcastingType: pick.broadcastingType, serviceID: pick.serviceID,
                                                 eventID: pick.eventID, start: pick.start,
                                                 durationSec: pick.durationSec, repeatType: repeatType))
            return ledger.entries.count - 1
        }
    }

    private func strike(_ entry: Int) throws {
        try change { $0.entries[entry].struck = true }
    }
}
