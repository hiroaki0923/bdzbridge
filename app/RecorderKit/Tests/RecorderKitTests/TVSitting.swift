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

    /// Picked from a recorder itself: its description, to see that it is one, and then its guide for the
    /// terrestrial stations and for each kind of broadcast a station named is of. What goes wrong is thrown
    /// by its kind alone (`TVSitting.said(ofTheRecorder:)`) and never as it came: a recorder's error carries
    /// the address it was sent to, and a test that throws one has it printed.
    static func picked(from recorder: RecorderClient, named: [Channel] = [], after now: Date) async throws -> TVPicks {
        var guide: [String: [GuideService]] = [:]
        do {
            _ = try await recorder.describe()
            for kind in Set(["td"] + named.compactMap { Codes.broadcasting(code: $0.broadcastingType) }).sorted() {
                guide[kind] = try await recorder.guide(kind) ?? []
            }
        } catch {
            throw TVSitting.Stopped(what: "the recorder's guide was not read: \(TVSitting.said(ofTheRecorder: error))")
        }
        return TVPicks(guide: guide, named: named, after: now)
    }

    static func read(_ file: URL) throws -> TVPicks { try TVFile.read(TVPicks.self, from: file) }
    func write(to file: URL) throws { try TVFile.write(self, to: file) }
}

/// What a sitting has made on the television, kept in a file outside the repository so that it outlives a
/// check that is killed half way. What is about to be made is written here before its create is sent --
/// the channel, the programme, the start, the length and the repeat, and no title -- and struck out once the
/// television has answered its delete and its list has shown that nothing of it is there. An entry is never
/// taken out: what the list is held against at the end is everything the sitting ever sent.
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
    /// When the first entry was written down, which is what says whose ledger this is. A sitting is one
    /// evening: a file begun more than a day ago is an earlier sitting's, named again by mistake, and its
    /// count is of another day's list.
    var begun: Date?

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
///   is held with it on. One check is for a television left in standby, and makes nothing unless it says
///   `standby`. Nor is anything made while the ledger holds an entry not struck out: something of an earlier
///   check may still be on the television, and a check that finds one fails and says so.
/// - **What a check deletes is only what it made.** The list is read before each create, and the check's own
///   are the recordings in the list read after it whose ids are new -- a television's ids only grow -- and
///   that are on the channel the create was sent for. Exactly those rows are deleted, each as it was last
///   read, and the list is read again to see them gone. Nothing is ever deleted by its programme, its time
///   or its title. A recording that is new and on another channel is somebody else's, set while the create
///   was out: it is left alone, and the check ends with its entry left open. So is any that is new after a
///   create the television answered as a reservation already there, which makes nothing.
/// - **The ledger** is written before a create is sent. An entry is struck out when every delete sent for it
///   was answered without an error and the list shows its rows gone and no recording it did not have before
///   the check, or when its create was answered with an error and the list shows nothing new. A check that
///   fails on the way takes off what it made before it ends, and says what it could not.
/// - **A ledger is one sitting's.** It says when its first entry was written, and beside one begun more than
///   a day ago nothing is made. An entry is struck out only while it is in the file as the check wrote it.
/// - **After silence on a create nothing is sent again.** The list is read, once; a row of the check's own
///   found there is deleted, and the check ends. With nothing found the entry stays open: a television may
///   carry a create out after the list was read, and somebody has to look.
/// - **A slot is empty before anything is put in it** (`isFree`): twenty hours or more ahead, and nothing of
///   the television's list within three hours either side.
/// - **Before every create the television is asked what the reservation would stop from recording**, by the
///   sitting's own client, and the create is not sent when the answer cannot be read or names a row that is
///   not the check's own. Two rows may be named: one the check itself has made and not yet taken off, and,
///   in the one check that is about it, the viewing reservation the owner set for the sitting.
/// - **A create the app's own round sends is held to the same.** The check for a television in standby sends
///   its create through the queue's flush and not from here. The ledger is written before each flush, the
///   list is read before it and after it, and the check's own rows are told as after any create. The
///   question before the create is the round's: it sends none when the television names any row at all, or
///   when its answer cannot be read. After silence nothing is sent again, by the round or from here.
/// - **Which viewing reservation is the sitting's is said by the owner**, by its start, and never guessed:
///   not the newest in the list, and not one found by its title.
/// - **Each request is sent once.** Nothing here asks again.
/// - **What is said** is counts, statuses, error codes, field names, weekdays, times of day and the repeat
///   read back: never a title, a station's name, an id of the television's, an address or a cookie. That
///   holds for what a check throws as well, so an error is said by its kind (`said`) and never as it came.
actor TVSitting {
    /// The title every reservation of a sitting is made under: the picks carry none, and no programme's is
    /// sent. It is not what a row left behind is known by: that is the ledger, and a television sent this
    /// title with a programme's id listed the reservation under a title of its own for the programme. Before
    /// that had been tried, a television was seen only to make a title's half-width spaces full-width. Which
    /// of the two it is, `held` says of each row, as a yes or a no.
    static let title = "BD Bridge 確認"
    /// How far ahead a programme has to be before a reservation of it is made.
    static let ahead: TimeInterval = 20 * 3600
    /// How far either side of a reservation the television's list has to be empty.
    static let margin: TimeInterval = 3 * 3600
    /// The longest a reservation with a repeat is left on the television to be looked at. While a check
    /// waits its reservation is there, and a check that is cut off leaves it there: the wait is kept to what
    /// somebody sits through.
    static let longestLook: TimeInterval = 120
    /// How long after its first entry was written a ledger is still the sitting's.
    static let longestSitting: TimeInterval = 24 * 3600
    /// The kinds of broadcast a television lists stations of, in the order they are asked for.
    static let kinds = ["td", "bs", "cs", "bs4k", "cs4k"]
    private static let terrestrial = Codes.broadcasting["td"] ?? 2

    /// Why a check did not run. Nothing was made.
    struct Refused: Error, Equatable {
        var why: String
    }

    /// What ended a check on the way, or what it found that it is not to find: said after everything that
    /// could be taken off was. And why nothing may be made until somebody has looked at the television: an
    /// entry of the ledger that was left open.
    struct Stopped: Error, Equatable {
        var what: String
    }

    private let client: ScalarClient
    private let picks: TVPicks
    private let ledgerFile: URL
    private let mayWrite: Bool
    private let reminderAt: Date?
    /// How long a reservation with a repeat is left to be looked at, in seconds.
    let look: TimeInterval
    private let now: @Sendable () -> Date
    private let say: @Sendable (String) -> Void

    /// What the check under way has made and not yet seen gone: each row as it was last read, and the
    /// ledger's entry it was made for.
    private var mine: [(row: TVScheduleRow, entry: Int)] = []
    /// The television's list as the check under way first read it, and as it last did.
    private var found: [TVScheduleRow]?
    private var last: [TVScheduleRow]?
    /// The entries of the check under way that stay open whatever becomes of their rows.
    private var keptOpen: Set<Int> = []
    /// The entries the check under way has written down, each as it wrote it: what an entry is known by
    /// again when it is struck out.
    private var noted: [Int: TVLedger.Entry] = [:]
    /// How many creates the check under way has sent.
    private var sent = 0

    /// `reminder` is the start of the viewing reservation the owner set for the sitting, for the checks that
    /// are about it. `look` is how long a reservation with a repeat is left on the television for the owner
    /// to read how its own list words it, never longer than `longestLook`. `now` and `say` are the clock and
    /// the terminal, which a rehearsal replaces.
    init(client: ScalarClient, picks: TVPicks, ledger: URL, mayWrite: Bool, reminder: Date? = nil,
         look: TimeInterval = 0, now: @escaping @Sendable () -> Date = { Date() },
         say: @escaping @Sendable (String) -> Void) {
        self.client = client
        self.picks = picks
        ledgerFile = ledger
        self.mayWrite = mayWrite
        reminderAt = reminder
        self.look = Self.looking(look)
        self.now = now
        self.say = say
    }

    // MARK: - what a sitting is given

    /// Whether a check may write: only when the leave it was given is the name of the very test that runs
    /// it, as `#function` gives that. A leave that only said yes would hold for every check a command
    /// happens to run -- the whole class, or whatever a later command runs with the variable still set --
    /// one after another with nobody watching.
    static func mayWrite(_ leave: String?, running test: String) -> Bool {
        leave == String(test.prefix { $0 != "(" })
    }

    /// The start the owner names the sitting's viewing reservation by, written `yyyy-MM-dd HH:mm` in Japan's
    /// time: the day and the minute its programme starts. Nil for anything else, a day that does not exist
    /// included.
    static func reminderStart(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = RecorderTime.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    /// How long a reservation is left to be looked at, for the seconds asked for: none for less than none
    /// or for no number, and never more than `longestLook`.
    static func looking(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isNaN ? 0 : min(max(seconds, 0), longestLook)
    }

    /// Where what a sitting says is kept as well as said: beside the ledger, under the ledger's own path with
    /// `.said` on it, so that wherever the ledger may be kept this may be too.
    static func saidFile(beside ledger: URL) -> URL { ledger.appendingPathExtension("said") }

    /// The terminal of a sitting at a real television. Each line is put out as it is said and not when the
    /// test ends: under `swift test` the output is a pipe, and what waits in a buffer is lost with a run that
    /// is cut off, while the reservation it was saying it had made is still on the television. And each line
    /// is added to the end of the file beside the ledger, which is opened, written and closed for that one
    /// line: whatever runs the command may show its output only when the command has ended, and what a check
    /// says while it waits is said for the time it is waiting. A file that cannot be written costs the check
    /// nothing: the line is still put out.
    static func printer(beside ledger: URL) -> @Sendable (String) -> Void {
        let path = saidFile(beside: ledger).path
        return { line in
            print(line)
            fflush(stdout)
            guard let file = fopen(path, "a") else { return }
            fputs(line + "\n", file)
            fclose(file)
        }
    }

    /// The working tree this file is in: the nearest directory above it that has a `.git`, or the package's
    /// own directory when there is none.
    static let tree: URL = {
        var package = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { package.deleteLastPathComponent() }
        var directory = package
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return package
    }()

    /// Whether a file of the sitting -- the picks, the ledger, the registration -- may be kept at `path`: an
    /// absolute path, and not one inside the working tree where git would pick the file up, which is
    /// anywhere in it but under `notes/`, the directory at its top that the repository ignores for what is
    /// not to be published. The picks and the ledger hold the stations a household receives, which say where
    /// it lives, and the registration is a key to its television: a relative path would put them beside the
    /// package, one `git add` from being public.
    static func mayKeep(at path: String, tree: URL = TVSitting.tree) -> Bool {
        guard path.hasPrefix("/") else { return false }
        func parts(_ url: URL) -> [String] { url.standardizedFileURL.resolvingSymlinksInPath().pathComponents }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let inside = parts(file.deletingLastPathComponent()) + [file.lastPathComponent], root = parts(tree)
        guard inside.starts(with: root) else { return true }
        return inside.count > root.count + 1 && inside[root.count] == "notes"
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
            let created = try await create(leave(for: body), of: pick)
            say("the create: \(created.answer); rows made: \(created.rows.count)")
            for row in created.rows { say("the row read back: \(Self.held(row, against: body))") }
            try await takeOff()
            guard created.taken, created.rows.count == 1 else { throw Stopped(what: "the create did not make one row") }
        }
    }

    /// A recording of the programme the household has a viewing reservation for: the question, the create,
    /// the list, the delete of the recording. Whether a viewing reservation stops the create, is named by
    /// the question, or is answered as the same programme a second time, is what it is run to see. The
    /// viewing reservation is the one the owner named (`theReminder`), the one row that is not the check's
    /// own that the question may name here, and is left as it was.
    func aRecordingWhereAViewingReservationIs() async throws {
        try await making {
            let listed = try await list()
            let reminder = try theReminder(in: listed)
            let pick = try programme(of: reminder)
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
            let created = try await create(leave(for: body, sparing: reminder), of: pick)
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
            let first = try await create(leave(for: body, "the first: "), of: pick)
            say("the first create: \(first.answer); rows made: \(first.rows.count)")
            guard first.taken, first.rows.count == 1 else { throw Stopped(what: "the first did not make one row") }
            let second = try await create(leave(for: body, "the second: "), of: pick)
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
    /// one test there is of which weekday a code means. Each is asked about, made, read back, left for the
    /// owner to read on the television's own list, and deleted before the next. The programme is one every
    /// one of the five is sent for, a weekday's from four in the morning, at a time of day nothing is listed
    /// at on any day.
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
                let name = "round \(round + 1), \(body.repeatType)"
                let created = try await create(leave(for: body, "\(name): "), of: pick)
                say("\(name) sent: \(created.answer); rows made: \(created.rows.count)")
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

    /// The repeats a television can be sent one of at a time, by a name a command can carry: the programme's
    /// own weekday, by its name, daily, Monday to Friday, Monday to Saturday.
    static let repeatsByName = ["weekly", "title", "daily", "weekdays", "weekdaysAndSaturday"]

    /// One repeat, alone, on the programme `theRepeats` uses: asked about, made, read back, left on the
    /// television until `looked` returns, and deleted. For an owner who reads the television's own list at
    /// their own pace, and cannot follow six in a row by the clock. Whoever hands `looked` in gives it an
    /// end: a reservation with a repeat is not left on a television on the strength of a word that may never
    /// come. A name that is not one of `repeatsByName` is refused before anything is sent.
    func oneRepeat(_ which: String, until looked: @Sendable () async -> Void) async throws {
        guard Self.repeatsByName.contains(which) else {
            throw Refused(why: "no such repeat to try: it is one of \(Self.repeatsByName.joined(separator: ", "))")
        }
        try await making {
            let listed = try await list()
            let stations = try await stations(of: Self.terrestrial)
            let (pick, station) = try choose(on: stations, in: listed, everyDay: true) {
                TVReservationBody.repeatType(for: "w15", start: $0.start) != nil
            }
            let own = (1...7).first { TVReservationBody.repeatType(for: "w\($0)", start: pick.start) != nil }
            guard let own else { throw Refused(why: "the programme chosen has no weekday code") }
            let codes = ["weekly": "w\(own)", "title": "S001", "daily": "d", "weekdays": "w15",
                         "weekdaysAndSaturday": "w16"]
            say("the programme: \(Self.when(pick.start))")
            let body = try body(pick, on: station, repeating: codes[which] ?? "1")
            let created = try await create(leave(for: body, "\(body.repeatType): "), of: pick)
            say("\(body.repeatType) sent: \(created.answer); rows made: \(created.rows.count)")
            for row in created.rows {
                say("  read back: repeatType \(row.repeatType ?? "none"), start \(Self.when(row))")
            }
            if !created.rows.isEmpty {
                say("  on the television's own list until it has been looked at: how is its repeat worded?")
                await looked()
                say("  looked at, and taken off now")
            }
            try await takeOff()
        }
    }

    /// Three at once, twice. First as it was measured by script: two at one time on two stations, and a
    /// third on a third station that starts later and overlaps them in part, in an empty slot. Then with the
    /// third starting before the two, beside the household's viewing reservation, which is on a station of
    /// its own inside the slot: whether the new row can be the one that loses, and whether the question can
    /// name a viewing reservation when both tuners are taken. Both arrangements are found before anything is
    /// made. The third is made only when every row the question names is the check's own: the first of the
    /// two is what a television was measured to name, and the third was taken all the same.
    func threeAtOnce() async throws {
        try await making {
            let listed = try await list()
            let reminder = try theReminder(in: listed)
            let stations = try await stations(of: Self.terrestrial)
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
    /// lets the app send it again once with a newer cookie. The question before it is the sitting's own
    /// client's, like every other.
    func aCreateWithACookieNotTaken(sentBy stranger: ScalarClient) async throws {
        try await making {
            let listed = try await list()
            let (pick, station) = try choose(on: try await stations(of: Self.terrestrial), in: listed)
            let leave = try await leave(for: body(pick, on: station))
            let created = try await create(leave, of: pick, by: stranger)
            say("the create with a cookie the television never gave: \(created.answer);"
                + " rows made: \(created.rows.count)")
            try await takeOff()
            guard case .http(403, _)? = created.failure as? ScalarError, created.rows.isEmpty else {
                throw Stopped(what: "a create with a cookie the television never gave was not refused for it")
            }
        }
    }

    /// The question and one create on each station named when the picks were written -- a station the
    /// television lists and does not receive, a station of a kind no reservation has been sent for -- and
    /// its delete where a row was made. The code a television answers a station it cannot show with, if it
    /// has one, is what the app is to hold such a row for: where it is the question that is answered with
    /// one, that is said, no create is sent for that station, and the next is still asked about. A station
    /// the television does not list is sent nothing.
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
                let asked: Asked
                do {
                    asked = try await question(body)
                } catch {
                    guard case .rpc? = error as? ScalarError else {
                        throw Stopped(what: "getConflictScheduleList: \(Self.said(error))")
                    }
                    say("\(name): the question: \(Self.said(error)), so no create is sent")
                    continue
                }
                say("\(name): \(asked.said)")
                guard let leave = asked.leave else {
                    say("\(name): a row that is not the check's own is named, so nothing is made")
                    continue
                }
                let created = try await create(leave, of: pick)
                say("\(name): \(created.answer); rows made: \(created.rows.count)")
                for row in created.rows { say("  the row read back: \(Self.held(row, against: body))") }
                try await takeOff()
            }
        }
    }

    /// One waiting reservation, sent as the app sends what waits for a television, to a television left in
    /// standby. It is queued in a store of the check's own, kept in memory so that nothing of it is on a
    /// disk at any time, and sent by the queue's own flush with the sitting's client: the round the app
    /// ships -- the disk, the list, the stations, the question, the create, the list. Then the same
    /// reservation is queued and flushed a second time, which is to find it on the television and send no
    /// create; and the row is taken off. Whether a write goes through hours into standby, and what the
    /// panel, the lamp and the disk do meanwhile, is what it is run to see.
    ///
    /// It makes nothing unless the television says `standby`, and is not begun on one whose disk is not
    /// there. The programme is the first among the picks with an empty slot that does not start in the small
    /// hours (`startsInTheSmallHours`) and of which the television holds no recording, by the rule the round
    /// finds one by (`holding`): a recording of it the round would take for the reservation at its opening
    /// and send nothing, and that recording would be the household's.
    ///
    /// What the queue says of a flush is all there is to go by, and it says a row was found there already
    /// both for one the round's opening found in the list and for one whose create was answered as held
    /// already and then found in the list. At the second flush it is the opening's: a row the list has after
    /// a create, by the one rule there is for finding it, the list had at the opening. How many creates went
    /// is counted where it can be, on the invented television.
    func aWaitingRowInStandby() async throws {
        try await making(in: "standby") {
            let disk = try await ask("getStorageList") { try await client.storage() }
            say("the disk: \(disk.mounted ? "mounted" : "not mounted")")
            guard disk.mounted else { throw Refused(why: "the television has no disk to record to") }
            let listed = try await list()
            say("the list: \(TVLedger.Counts(listed).said)")
            let (pick, station) = try choose(on: try await stations(of: Self.terrestrial), in: listed) {
                !Self.startsInTheSmallHours($0.start) && listed.holding(Self.request($0)) == nil
            }
            let body = try body(pick, on: station)
            let waiting = PendingReservation(request: Self.request(pick), serviceName: "", queuedAt: now(),
                                             target: .tv)
            guard let store = try? GuideStore(path: ":memory:") else {
                throw Refused(why: "the check's own queue could not be made")
            }

            let first = try await flush(waiting, of: pick, repeating: body.repeatType, through: store,
                                        "the first flush")
            for row in first.rows { say("the row read back: \(Self.held(row, against: body))") }
            guard first.outcome.sent.count == 1, first.rows.count == 1 else {
                throw Stopped(what: "the first flush did not make one row")
            }
            let second = try await flush(waiting, of: pick, repeating: body.repeatType, through: store,
                                         "the second flush")
            try await takeOff()
            guard second.outcome.alreadyThere.count == 1, second.outcome.sent.isEmpty else {
                throw Stopped(what: "the same row a second time was not found on the television")
            }
        }
    }

    /// Whether a programme starts in the small hours in Japan: from midnight until five in the morning. The
    /// check for a television in standby reserves none that does. It is run in the morning, and twenty hours
    /// ahead of a morning falls there. A station may be off the air then, a guide lists that as a programme
    /// like any other, and what a television answers a create for one has not been seen: a create turned
    /// down for it would say nothing of standby, and the one night the check has is not for finding it out.
    static func startsInTheSmallHours(_ start: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        return calendar.component(.hour, from: start) < 5
    }

    /// The count afterwards. Fails unless the ledger has every entry struck out, the list holds no
    /// recording an entry may have left behind -- a struck one as well: what a television answered with an
    /// error it may have made all the same -- and the list counts as it did before the first create. And
    /// fails, with nothing sent, on a ledger that holds nothing of a sitting: a file that is not the one the
    /// checks wrote in says of whatever is on the television that nothing was ever made. Nor is a ledger
    /// begun more than a day ago this sitting's. When nothing is wrong it says so, in one line that nothing
    /// else says: a run that was skipped looked at nothing, and reads as no failure all the same.
    func whatIsLeft() async throws {
        let ledger = try ledgerOfTheSitting()
        guard let before = ledger.before else {
            throw Stopped(what: "the ledger holds nothing of a sitting: no create was ever written down in it."
                          + " It is one file for the whole sitting, the one every check was given")
        }
        let listed = try await ask("getScheduleList") { try await client.schedules() }
        let counts = TVLedger.Counts(listed)
        let left = listed.filter { row in ledger.entries.contains { $0.mayHaveLeft(row) } }
        say("the list: \(counts.said); before the first create: \(before.said)")
        say("the ledger: entries \(ledger.entries.count), not struck out \(ledger.open);"
            + " recordings listed that one of them may have left: \(left.count)")
        var wrong: [String] = []
        if ledger.open > 0 { wrong.append("entries of the ledger not struck out: \(ledger.open)") }
        if !left.isEmpty { wrong.append("recordings listed that may be the sitting's: \(left.count)") }
        if before != counts { wrong.append("the list does not count as it did") }
        guard wrong.isEmpty else { throw Stopped(what: wrong.joined(separator: "; ")) }
        say("nothing of the sitting is left")
    }

    // MARK: - what every check that makes something is made of

    /// A check that makes something: behind the guard, and with what it made taken off again however it
    /// ends. A check that fails on the way does not leave what it had made by then, and what could not be
    /// taken off is said with what failed. Afterwards the list is to read as it did before the check began.
    /// `power` is what the television has to say it is for the check to run: on, unless the check is the one
    /// for a television in standby.
    private func making(in power: String = "active", _ check: () async throws -> Void) async throws {
        (mine, found, last, keptOpen, noted, sent) = ([], nil, nil, [], [:], 0)
        try await mayMake(in: power)
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
    /// ledger is not so much as read. An entry left open is not a check that merely did not run: something
    /// of the sitting may be on the television, so it is thrown as what stops the sitting, and the test
    /// fails. So it does beside a ledger that is another sitting's. Last, the television is asked what it
    /// says it is, and the check does not run unless that is `wanted`.
    private func mayMake(in wanted: String) async throws {
        guard mayWrite else { throw Refused(why: "writing to the television was not asked for") }
        let open = try ledgerOfTheSitting().open
        guard open == 0 else {
            throw Stopped(what: "entries of the ledger not struck out: \(open). Something of the sitting may be"
                          + " on the television: see on its own list that nothing of them is there, and strike"
                          + " them out, before anything more is made")
        }
        let power = try await ask("getPowerStatus") { try await client.powerStatus() }
        guard power == wanted else {
            throw Refused(why: "the television says it is \(power), and this is a check for one that is "
                          + (wanted == "active" ? "on" : "in standby"))
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

    /// Leave to send one create: for the reservation the television has just been asked about, when every
    /// row its answer named may be named. Only `question` hands one out, and `create` sends nothing without
    /// one, which is what puts the question before every create there is.
    private struct Leave: Sendable {
        fileprivate let body: TVReservationBody
    }

    /// What the television answered the question before a create: the rows it named, and leave to send the
    /// create when there is nothing against it.
    private struct Asked: Sendable {
        var named: [TVScheduleRow]
        var leave: Leave?

        /// How many rows were named and of which types: never which.
        var said: String {
            "rows the question names: \(named.count)"
                + (named.isEmpty ? "" : ", of type \(named.map(\.type).joined(separator: ", "))")
        }
    }

    /// Asks what a reservation would stop from recording, once, by the sitting's own client whoever is to
    /// send the create. There is leave to send it when every row the answer names is one the check has made
    /// and not yet taken off, or is `reminder`, the sitting's viewing reservation, in the check that is
    /// about it: any other row is somebody's reservation that the create would cost them. An answer that
    /// cannot be read is thrown, and is no leave either.
    private func question(_ body: TVReservationBody, sparing reminder: TVScheduleRow? = nil) async throws -> Asked {
        let named = try await client.wouldPushOut(body)
        let own = Set(mine.map(\.row.id))
        let spared = named.allSatisfy { own.contains($0.id) || $0.id == reminder?.id }
        return Asked(named: named, leave: spared ? Leave(body: body) : nil)
    }

    /// The question before a create, said under `label`, and the leave it gives. Without leave the check
    /// goes no further: it did not run, when it has sent no create yet, and is stopped on the way otherwise,
    /// with what it made taken off as it ends.
    private func leave(for body: TVReservationBody, _ label: String = "",
                       sparing reminder: TVScheduleRow? = nil) async throws -> Leave {
        let asked = try await ask("getConflictScheduleList") { try await question(body, sparing: reminder) }
        var said = label + asked.said
        if let reminder {
            let among = asked.named.contains { $0.id == reminder.id }
            said += "; the viewing reservation among them: \(among ? "yes" : "no")"
        }
        say(said)
        guard let leave = asked.leave else {
            let why = "the television says the reservation would stop one that is not the check's own"
            guard sent > 0 else { throw Refused(why: why) }
            throw Stopped(what: "\(label)\(why), so it is not made")
        }
        return leave
    }

    /// What a create came to: the error it was answered with, or none when it was taken and then the number
    /// its answer said, and the rows the list shows it made.
    private struct Created {
        var failure: (any Error)?
        var annotation: Int?
        var rows: [TVScheduleRow]

        var taken: Bool { failure == nil }
        var answer: String { failure.map(TVSitting.said(_:)) ?? TVSitting.taken(annotation) }
    }

    /// One create, sent once, by `sender` or by the sitting's own client, with the leave the question before
    /// it gave: the ledger first, then the request, then the list, whatever the answer and after none
    /// (`made`).
    private func create(_ leave: Leave, of pick: TVPick, by sender: ScalarClient? = nil) async throws -> Created {
        var listed = last
        if listed == nil { listed = try await list() }
        let before = Set((listed ?? []).map(\.id))
        let entry = try note(pick, repeating: leave.body.repeatType)
        var failure: (any Error)?
        var annotation: Int?
        sent += 1
        do { annotation = try await (sender ?? client).addSchedule(leave.body) } catch { failure = error }
        let kind = (failure as? ScalarError)?.failure
        let sending = Sending(a: "a create", the: "the create",
                              answer: failure.map(Self.said(_:)) ?? Self.taken(annotation),
                              madeNothing: kind == .alreadyThere, mayBeTaken: failure == nil, silent: kind == .silent)
        let rows = try await made(by: sending, noted: entry, of: pick, before: before)
        return Created(failure: failure, annotation: annotation, rows: rows)
    }

    /// Something sent that may have made a reservation, as far as its answer goes: a create, or a round of
    /// the queue's, which may have sent one. What the list read after it is held against (`made`).
    private struct Sending {
        /// What it is called where it is said, with `a` and with `the`: a create, the create.
        var a: String
        var the: String
        /// What it was answered, as that is said.
        var answer: String
        /// Whether its answer says that nothing was made for it: a reservation already there.
        var madeNothing: Bool
        /// Whether a create may have been taken, as far as its answer says.
        var mayBeTaken: Bool
        /// Whether a create met no answer.
        var silent: Bool
    }

    /// The list after something was sent that may have made a reservation, read once whatever was answered
    /// and after no answer, and the rows of it that are the check's own from here on.
    ///
    /// Those are the recordings whose ids the list read before did not have (`before`) and that are on the
    /// channel the reservation was sent for. A recording that is new and on another channel was set by
    /// somebody else meanwhile, with the remote or from another device: it is not touched, the entry is
    /// left open so that somebody looks, and the check ends, its own row taken off as it does.
    ///
    /// A create answered as a reservation already there was measured to make nothing, so no row is the
    /// check's own after it. A recording that is new then is somebody else's as well, on the channel or off
    /// it: most likely theirs for the very programme, set a moment before, which is what the television was
    /// answering about.
    ///
    /// An entry whose create was answered with an error and made nothing is struck out at once. One whose
    /// create was taken, or may have been, and shows nothing in the list is left open, and the check ends:
    /// something may be there that the list did not show. After silence the check ends as well: nothing is
    /// sent again, what the list showed of the create is taken off as the check ends, and where it showed
    /// nothing the entry is left open, since a television may carry out afterwards a create it never
    /// answered.
    private func made(by sending: Sending, noted entry: Int, of pick: TVPick,
                      before: Set<String>) async throws -> [TVScheduleRow] {
        let after: [TVScheduleRow]
        do {
            after = try await list()
        } catch {
            throw Stopped(what: "\(Self.told(error)) after \(sending.a) (\(sending.answer)):"
                          + " what it made is not known, and its entry is left in the ledger")
        }
        let new = after.filter { $0.type == "recording" && !before.contains($0.id) }
        let rows = sending.madeNothing ? [] : new.filter { row in
            TVScheduleRow.channel(of: row.uri).map { $0 == (pick.broadcastingType, pick.serviceID) } == true
        }
        mine += rows.map { ($0, entry) }
        guard rows.count == new.count else {
            keptOpen.insert(entry)
            throw Stopped(what: "recordings new in the list that \(sending.the) did not make:"
                          + " \(new.count - rows.count). They are on another channel than it was sent for, or it"
                          + " was answered as already there and made nothing: they are not the check's and are"
                          + " left alone; \(sending.the) (\(sending.answer)) made rows of its own: \(rows.count),"
                          + " and its entry is left in the ledger")
        }
        if rows.isEmpty, !sending.silent {
            guard !sending.mayBeTaken else {
                throw Stopped(what: "\(sending.a) (\(sending.answer)) shows nothing new in the list: its entry is"
                              + " left in the ledger")
            }
            try strike(entry)
        }
        if sending.silent {
            throw Stopped(what: "\(sending.a) met no answer, and nothing is sent again; rows it made: \(rows.count)"
                          + (rows.isEmpty ? ". The television may yet carry it out: its entry is left in the"
                              + " ledger" : ""))
        }
        return rows
    }

    /// What a flush of the check's own queue came to: what the queue said of the round, and the rows the
    /// list shows it made.
    private struct Flushed {
        var outcome: PendingQueue.Outcome
        var rows: [TVScheduleRow]
    }

    /// One waiting reservation, queued in `store` and sent by the queue's own flush with the sitting's
    /// client, once: the round the app ships. The create is the round's to send and not `create`'s, so what
    /// is kept around a create is kept around the flush, which may send one: the ledger first, then the
    /// flush, then the list, whatever the queue says of the round (`made`).
    ///
    /// Nothing was made, whatever is new in the list, when the queue says the reservation was found on the
    /// television already. A create may have been taken unless what the queue says shows that none was
    /// (`tookNoCreate`), and silence that a create may have met is the round's stop for it. The question
    /// before the create is the round's own.
    private func flush(_ waiting: PendingReservation, of pick: TVPick, repeating repeatType: String,
                       through store: GuideStore, _ name: String) async throws -> Flushed {
        var listed = last
        if listed == nil { listed = try await list() }
        let before = Set((listed ?? []).map(\.id))
        do { try await store.queue(waiting) } catch { throw Stopped(what: "the check's own queue cannot be written") }
        let entry = try note(pick, repeating: repeatType)
        let outcome = await PendingQueue.flush(client: client, store: store, now: now())
        let answer = Self.said(ofARound: outcome)
        say("\(name): \(answer)")
        let sending = Sending(a: name, the: name, answer: answer, madeNothing: !outcome.alreadyThere.isEmpty,
                              mayBeTaken: !Self.tookNoCreate(outcome),
                              silent: outcome.stopped == .silent(afterSending: true))
        let rows = try await made(by: sending, noted: entry, of: pick, before: before)
        say("\(name): rows made: \(rows.count)")
        return Flushed(outcome: outcome, rows: rows)
    }

    /// Takes off what the check has made and not yet seen gone: each row as it was last read, each delete
    /// sent once, and then the list, read once, to see them gone. An entry is struck out only when every
    /// delete sent for it was answered without an error and none of its rows is listed any more: a delete
    /// the television refused is of a row it no longer has under that number, which may be there under
    /// another. And nothing at all is struck out while the list holds a recording it did not have when the
    /// check began: a television may list again, under a new number, what it has just answered a delete of,
    /// and that cannot be told from a recording somebody set meanwhile. It is left alone, and somebody
    /// looks. Anything else stays in the ledger and is thrown; nothing is tried a second time.
    private func takeOff() async throws {
        let taking = mine
        mine = []
        guard !taking.isEmpty else { return }
        var unanswered: [Int] = []
        for held in taking {
            do {
                try await client.deleteSchedule(held.row)
            } catch {
                say("  a delete: \(Self.said(error))")
                unanswered.append(held.entry)
            }
        }
        let after: [TVScheduleRow]
        do {
            after = try await list()
        } catch {
            throw Stopped(what: "\(Self.told(error)) after the deletes: whether they took is not known,"
                          + " and their entries are left in the ledger")
        }
        let left = taking.filter { held in after.contains { $0.id == held.row.id } }
        let before = Set((found ?? []).map(\.id))
        let new = after.filter { $0.type == "recording" && !before.contains($0.id) }
        let open = Set(unanswered + left.map(\.entry)).union(keptOpen)
        if new.isEmpty {
            for entry in Set(taking.map(\.entry)) where !open.contains(entry) { try strike(entry) }
        }
        guard left.isEmpty, unanswered.isEmpty, new.isEmpty else {
            throw Stopped(what: "deletes that were not answered as taken: \(unanswered.count); rows the check made"
                          + " that are still listed after their delete: \(left.count); recordings listed that"
                          + " were not there before the check: \(new.count). "
                          + (new.isEmpty ? "Their entries are left in the ledger"
                              : "Nothing is struck out while one of those is listed: the entries of everything"
                              + " taken off are left in the ledger"))
        }
    }

    /// The question and the create for each of two at one time, then the question for a third, which is
    /// made when every row that question names is one of the two; then what each of them reads as, and all
    /// of them taken off.
    private func arrange(_ name: String, _ three: Three, beside reminder: TVScheduleRow?) async throws {
        var roles: [String: String] = [:]
        for (role, programme) in [("the first", three.a), ("the second", three.b)] {
            let leave = try await leave(for: body(programme.pick, on: programme.station), "\(name), \(role): ")
            let created = try await create(leave, of: programme.pick)
            say("\(name), \(role): \(created.answer); rows made: \(created.rows.count)")
            guard created.taken, created.rows.count == 1 else { throw Stopped(what: "\(role) did not make one row") }
            roles[created.rows[0].id] = role
        }
        let third = try body(three.c.pick, on: three.c.station)
        let asked = try await ask("getConflictScheduleList") { try await question(third) }
        let who = asked.named.map { row in
            roles[row.id] ?? (row.id == reminder?.id ? "the viewing reservation" : "another \(row.type)")
        }
        say("\(name), rows the question for the third names: \(asked.named.count)"
            + (who.isEmpty ? "" : " (\(who.joined(separator: ", ")))"))
        if let leave = asked.leave {
            if !asked.named.isEmpty { say("\(name): every row named is the check's own, so the third is made") }
            let created = try await create(leave, of: three.c.pick)
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

    /// A reservation of `pick` as the app asks for one, under the sitting's title.
    private static func request(_ pick: TVPick, repeating code: String = "1") -> ReservationRequest {
        ReservationRequest(title: title, start: pick.start, durationSec: pick.durationSec, repeatCode: code,
                           broadcastingType: pick.broadcastingType, serviceID: pick.serviceID,
                           qualityCode: Codes.quality["DR"] ?? 100, eventID: pick.eventID)
    }

    /// A reservation of `pick` on `station` as the app writes one, under the sitting's title.
    private func body(_ pick: TVPick, on station: TVStation, repeating code: String = "1") throws -> TVReservationBody {
        guard let body = TVReservationBody(Self.request(pick, repeating: code), on: station) else {
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

    /// The viewing reservation of the sitting, as the list has it: the one reminder that starts within a
    /// minute of the start the owner named. Within a minute and not to the second: a television lists a
    /// reminder's start a second before its programme's. With none named, none found or more than one, the
    /// check does not run. It is never the newest in the list, or one found by its title: a check goes on to
    /// reserve the programme of whichever row this is, and a household has viewing reservations of its own.
    private func theReminder(in listed: [TVScheduleRow]) throws -> TVScheduleRow {
        guard let named = reminderAt else {
            throw Refused(why: "the sitting was not told which viewing reservation is its own: its start is"
                          + " given beside the command")
        }
        let near = listed.filter { row in
            row.type == "reminder"
                && RecorderTime.parse(row.startDateTime).map { abs($0.timeIntervalSince(named)) <= 60 } == true
        }
        guard near.count == 1 else {
            throw Refused(why: "viewing reservations listed that start within a minute of the start that was"
                          + " named: \(near.count), where one is looked for")
        }
        return near[0]
    }

    /// The programme of a viewing reservation among the picks: on its channel, with its programme id.
    private func programme(of reminder: TVScheduleRow) throws -> TVPick {
        let pick = picks.programmes.first { pick in
            TVScheduleRow.channel(of: reminder.uri).map { $0 == (pick.broadcastingType, pick.serviceID) } == true
                && reminder.eventId == String(pick.eventID)
        }
        guard let pick else { throw Refused(why: "the viewing reservation's programme is not among the picks") }
        return pick
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

    /// The fields of a row that was made, each held against what was sent: by their names, never their
    /// values. The uri byte for byte, the start as text. And whether the title read back is the one that was
    /// sent with its half-width spaces made full-width. A no is a television that lists a reservation under
    /// a title of its own for the programme, which is what a real one answered the sitting's creates with:
    /// the title itself is never said.
    static func held(_ row: TVScheduleRow, against body: TVReservationBody) -> String {
        let fields: [(String, Bool)] = [
            ("uri", row.uri.utf8.elementsEqual(body.uri.utf8)),
            ("startDateTime", row.startDateTime == body.startDateTime),
            ("durationSec", row.durationSec == body.durationSec), ("eventId", row.eventId == body.eventId),
            ("repeatType", row.repeatType == body.repeatType), ("type", row.type == "recording"),
            ("quality", row.quality == "DR"),
        ]
        let other = fields.filter { !$0.1 }.map(\.0)
        let widened = body.title.replacingOccurrences(of: " ", with: "\u{3000}")
        let title = row.title.map { $0.unicodeScalars.elementsEqual(widened.unicodeScalars) } == true
        return (other.isEmpty ? "every field as sent, in DR" : "not as sent: \(other.joined(separator: ", "))")
            + "; its title is the one sent with its spaces widened: \(title ? "yes" : "no")"
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

    /// A create that was taken, with the number its answer said. Nought is all a television has been seen
    /// to say, so any other is something learnt, and it is said as it came.
    static func taken(_ annotation: Int?) -> String {
        "taken, " + (annotation.map { "annotation \($0)" } ?? "with no annotation")
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

    /// What the queue said of a round of sending, by its counts and its stop. Never a reason as the round
    /// wrote it on a row, nor what the device said of the rows it made: those are sentences for the app's
    /// reader, and name the household's reservations by their titles. A reason is said by its kind.
    static func said(ofARound outcome: PendingQueue.Outcome) -> String {
        let reasons = outcome.refused.map { kind(ofAReason: $0.problem).said }.joined(separator: "; ")
        let stop: String
        switch outcome.stopped {
        case nil: stop = "not stopped"
        case .silent(let afterSending)?:
            stop = "stopped by silence, " + (afterSending ? "at a create or after it" : "before a create")
        case .needsPairing?: stop = "stopped: the registration is wanted again"
        case .cannotRecord?: stop = "stopped: no disk to record to"
        case .saysNothing?: stop = "stopped: answers that say nothing"
        }
        return "sent \(outcome.sent.count), found there already \(outcome.alreadyThere.count), held with a reason"
            + " \(outcome.refused.count)" + (reasons.isEmpty ? "" : " (\(reasons))")
            + ", passed over \(outcome.deferred.count), dropped as over \(outcome.expired.count), held from before"
            + " \(outcome.held.count), said of what was made \(outcome.remarks.count); \(stop)"
    }

    /// A reason the round wrote on a row, by its kind, and whether a row held for it is one no create was
    /// taken for. The one reason that says a create was taken is the one for a create answered as taken
    /// whose reservation the list does not have. A reason not known here says neither.
    private static func kind(ofAReason reason: String?) -> (said: String, noCreateTaken: Bool) {
        guard let reason else { return ("no reason", false) }
        if reason.hasPrefix(ScalarClient.wouldStop) { return ("it would stop another from recording", true) }
        if let code = ScalarClient.refusals.first(where: { $0.value == reason })?.key {
            return ("turned down with error \(code)", true)
        }
        switch reason {
        case ScalarClient.stationNotListed: return ("its station is not in the television's list", true)
        case ScalarClient.saidThereNotListed: return ("answered as there already, and not in the list", true)
        case ScalarClient.acceptedNotListed: return ("answered as taken, and not in the list", false)
        case ScalarClient.needsAProgramme, ScalarClient.repeatNotTaken: return ("not one a television is sent", true)
        default: return ("a reason of another kind", false)
        }
    }

    /// Whether what the queue said of a round shows that no create of it was taken: the reservation found on
    /// the television already, or held with a reason that says so; or the round stopped where none had gone
    /// out, for the disk or for silence before one. Anything else does not say, and is not taken for a no:
    /// a round passes a row over for a create whose answer, or the list after it, it could not read, as it
    /// does for a question it could not; and a stop for the registration, or for answers that say nothing,
    /// does not say where it came.
    static func tookNoCreate(_ outcome: PendingQueue.Outcome) -> Bool {
        guard outcome.sent.isEmpty, outcome.deferred.isEmpty else { return false }
        guard outcome.refused.isEmpty else {
            return outcome.refused.allSatisfy { kind(ofAReason: $0.problem).noCreateTaken }
        }
        if !outcome.alreadyThere.isEmpty { return true }
        switch outcome.stopped {
        case .cannotRecord?, .silent(afterSending: false)?: return true
        default: return false
        }
    }

    /// What answers at an address, by its kind alone. A television's model is not said: which one a
    /// household has is no more a check's to print than what it records.
    static func said(ofWhatAnswers presence: TVPresence) -> String {
        switch presence {
        case .nothing: "nothing"
        case .notATelevision: "something that is not a television"
        case .standby: "a television, in standby"
        case .on: "a television, on"
        }
    }

    /// What kept a recorder's guide from being read, by its kind alone: no answer, something that is not a
    /// recorder, an address nothing can be sent to, or an answer that could not be read. Never the error as
    /// it came, whose text has the address in it.
    static func said(ofTheRecorder error: any Error) -> String {
        if case .notARecorder? = error as? RecorderError { return "not a recorder" }
        switch (error as? any DeviceError)?.failure {
        case .silent?: return "no answer"
        case .badAddress?: return "an address nothing can be sent to"
        default: return "an answer that could not be read"
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

    /// The ledger, when it is this sitting's. One begun more than a day ago is not: it is thrown as what
    /// stops the sitting, with nothing sent. Taken up again, its count would be of another day's list and
    /// its entries of what another sitting made.
    private func ledgerOfTheSitting() throws -> TVLedger {
        let ledger = try ledger()
        if let begun = ledger.begun, now().timeIntervalSince(begun) > Self.longestSitting {
            throw Stopped(what: "the ledger was begun more than a day ago, and has entries not struck out:"
                          + " \(ledger.open). It is another sitting's: a sitting writes in a file of its own,"
                          + " one that is not there before its first check")
        }
        return ledger
    }

    /// Reads the ledger, changes it and writes it back. A change that throws writes nothing.
    private func change<T>(_ change: (inout TVLedger) throws -> T) throws -> T {
        var ledger = try ledger()
        let result = try change(&ledger)
        do { try ledger.write(to: ledgerFile) } catch { throw Stopped(what: "the ledger cannot be written") }
        return result
    }

    /// Writes down what is about to be made, before it is sent: a ledger that cannot be written ends the
    /// check with nothing sent. The first entry of a sitting has the list's counts written beside it, and
    /// the time.
    private func note(_ pick: TVPick, repeating repeatType: String) throws -> Int {
        let counts = last.map { TVLedger.Counts($0) }, at = now()
        let entry = TVLedger.Entry(broadcastingType: pick.broadcastingType, serviceID: pick.serviceID,
                                   eventID: pick.eventID, start: pick.start, durationSec: pick.durationSec,
                                   repeatType: repeatType)
        let place = try change { ledger in
            if ledger.before == nil { ledger.before = counts }
            if ledger.begun == nil { ledger.begun = at }
            ledger.entries.append(entry)
            return ledger.entries.count - 1
        }
        noted[place] = entry
        return place
    }

    /// Strikes out an entry the check under way wrote down, while it is in the file as it was written: at
    /// its place, and not yet struck out. The file is read and written with no lock, and an entry is known
    /// by its place in it. So a file taken away or written over meanwhile -- by hand, or by a second command
    /// run at the same moment -- is not the ledger this check wrote in: going by the place alone would
    /// strike out an entry that is somebody else's, and would stop the process where the place is gone, in
    /// the middle of a check, with what it had not yet taken off left on the television.
    private func strike(_ entry: Int) throws {
        try change { ledger in
            guard ledger.entries.indices.contains(entry), ledger.entries[entry] == noted[entry] else {
                throw Stopped(what: "the ledger is not the one this check wrote in: an entry it wrote down is not"
                              + " there as it was written, and nothing is struck out")
            }
            ledger.entries[entry].struck = true
        }
    }
}
