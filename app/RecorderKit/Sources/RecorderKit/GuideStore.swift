import Foundation

/// One channel as the cache holds it, in the user's order with its logo attached.
public struct Channel: Sendable, Equatable, Identifiable {
    public var broadcasting: String
    public var serviceID: Int
    public var name: String
    /// The recorder's own order.
    public var sort: Int
    public var hidden: Bool
    /// Where the user moved it, if they did.
    public var position: Int?
    public var logo: Data?

    public var id: String { "\(broadcasting)-\(serviceID)" }
}

/// A programme from the cache: the channel's name filled in, and a sub-channel reference resolved to the text
/// of the programme it points at.
public struct GuideProgramRow: Sendable, Hashable, Identifiable {
    public var broadcasting: String
    public var serviceID: Int
    public var serviceName: String
    public var eventID: Int
    public var start: Date
    public var end: Date
    public var title: String
    public var summary: String
    public var extended: String
    public var genres: [Genre]
    public var copyControl: Int
    public var parental: Int
    public var isReference: Bool
    public var referenceServiceID: Int?
    public var referenceEventID: Int?

    public var id: String { "\(broadcasting)-\(serviceID)-\(eventID)-\(Int(start.timeIntervalSince1970))" }
    public var durationSec: Int { Int(end.timeIntervalSince(start)) }
    public var genre: Genre? { genres.first }
}

/// Which part of a programme a search found its words in. Results come best first: a programme named for
/// what was looked for, then one whose description mentions it, then one that has it only in its details,
/// which is where the cast is listed. With several words, a programme ranks by the one found furthest down.
public enum SearchMatch: Int, Sendable, Comparable {
    case title, summary, extended

    public static func < (lhs: SearchMatch, rhs: SearchMatch) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct GuideSearchHit: Sendable, Hashable, Identifiable {
    public var program: GuideProgramRow
    public var match: SearchMatch
    /// For a programme found only in its details, the words around what was found: the row shows the title
    /// and the description, and neither would say why the programme is there.
    public var snippet: Search.Snippet?

    public var id: String { program.id }
}

public struct GuideSearchResults: Sendable, Hashable {
    public var hits: [GuideSearchHit]
    /// More programmes matched than were given back, so the reader should narrow the words rather than
    /// take the list for all there is.
    public var more: Bool

    public init(hits: [GuideSearchHit] = [], more: Bool = false) {
        self.hits = hits
        self.more = more
    }
}

public struct GuideCounts: Sendable, Equatable {
    public var channels: Int
    public var programs: Int
    /// When this broadcasting type was last refreshed, as the recorder's local time.
    public var refreshed: String?
    /// When the recorder last answered for this broadcasting type, with its guide or with none to give: the
    /// same as `refreshed` for a type it has, and the only mark on one it does not. What decides whether a
    /// type is fetched again. Nil in a cache written before this was kept, where `refreshed` stands in.
    public var checked: String?

    /// When this broadcasting type was last asked for and answered, as a date.
    public var lastAnswered: Date? { (checked ?? refreshed).flatMap(RecorderTime.parse) }
}

/// The guide cache on the device: channels, programmes, station logos, and which channels the user hides or
/// reorders. The cache tables are disposable and are rebuilt when the schema changes; the user's own
/// preferences survive that.
public actor GuideStore {
    static let currentSchemaVersion = "1"

    /// What `programs.search_text` is made of. When that changes, a cache written the old way is brought up
    /// to date where it is, by `updateSearchText`, rather than by a new schema version: that would throw the
    /// guide away, and away from home it cannot be fetched again. 2 added the details, and separated the
    /// fields so that a search can say which one it found its words in.
    static let currentSearchTextVersion = "2"

    private let db: Sqlite
    /// Set once the search text is known to be current, so that a search does not ask the database each time.
    private var searchTextIsCurrent = false

    private static let schema = """
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS channels (
      bt TEXT NOT NULL, service_id INTEGER NOT NULL, name TEXT NOT NULL, sort INTEGER NOT NULL,
      PRIMARY KEY (bt, service_id));
    CREATE TABLE IF NOT EXISTS programs (
      bt TEXT NOT NULL, service_id INTEGER NOT NULL, event_id INTEGER NOT NULL,
      start INTEGER NOT NULL, end INTEGER NOT NULL,
      title TEXT, description TEXT, extended TEXT, genre1 INTEGER, genre2 INTEGER, genres TEXT,
      copy_control INTEGER, parental INTEGER, ref_service_id INTEGER, ref_event_id INTEGER,
      search_text TEXT,
      PRIMARY KEY (bt, service_id, event_id, start));
    CREATE TABLE IF NOT EXISTS logos (
      bt TEXT NOT NULL, service_id INTEGER NOT NULL, channel_no INTEGER NOT NULL, png BLOB NOT NULL,
      PRIMARY KEY (bt, service_id));
    CREATE TABLE IF NOT EXISTS channel_prefs (
      bt TEXT NOT NULL, service_id INTEGER NOT NULL, hidden INTEGER NOT NULL DEFAULT 0, position INTEGER,
      PRIMARY KEY (bt, service_id));
    CREATE TABLE IF NOT EXISTS title_summaries (id TEXT PRIMARY KEY, summary TEXT NOT NULL, at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS pending_reservations (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, start INTEGER NOT NULL, duration_sec INTEGER NOT NULL,
      repeat_code TEXT NOT NULL, bt INTEGER NOT NULL, service_id INTEGER NOT NULL, service_name TEXT NOT NULL,
      quality_code INTEGER NOT NULL, event_id INTEGER, queued_at INTEGER NOT NULL, problem TEXT);
    CREATE INDEX IF NOT EXISTS ix_programs_time ON programs (bt, service_id, start);
    CREATE INDEX IF NOT EXISTS ix_programs_start ON programs (bt, start);
    CREATE INDEX IF NOT EXISTS ix_programs_ref ON programs (bt, ref_event_id);
    """

    public init(path: String) throws {
        try self.init(path: path, schemaVersion: Self.currentSchemaVersion)
    }

    init(path: String, schemaVersion: String) throws {
        let db = try Sqlite(path: path)
        try db.execute(Self.schema)
        let stored = try db.query("SELECT value FROM meta WHERE key='schema_version'") { $0.string("value") }.first
        if stored != schemaVersion {
            // the guide is a cache and can be fetched again; what the user set is not thrown away
            try db.execute("""
            DROP TABLE IF EXISTS programs;
            DROP TABLE IF EXISTS channels;
            DROP TABLE IF EXISTS logos;
            DELETE FROM meta WHERE key LIKE 'epg_refreshed:%';
            DELETE FROM meta WHERE key LIKE 'epg_checked:%';
            """)
            try db.execute(Self.schema)
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?)",
                       [.text(schemaVersion)])
            // Nothing is left to bring up to date, and what `replace` writes from here on is current.
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('search_text_version', ?)",
                       [.text(Self.currentSearchTextVersion)])
        }
        // The duplicate scan used to store a failed read as an empty text and never ask again, so an empty row
        // from before may be a failure rather than a recording with no text. They are thrown away once, and
        // asked about again at the next scan; an empty text read from now on is a real answer and is kept. A
        // schema change would not do it, since the summaries are not among the tables it rebuilds.
        if try db.count("SELECT COUNT(*) FROM meta WHERE key='blank_summaries_cleared'") == 0 {
            try db.transaction {
                try db.run("DELETE FROM title_summaries WHERE summary=''")
                try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('blank_summaries_cleared', '1')")
            }
        }
        self.db = db
    }

    // MARK: - refresh

    /// Replaces everything held for one broadcasting type. Returns how many programmes were stored.
    @discardableResult
    public func replace(_ services: [GuideService], broadcasting: String, at now: Date = Date()) throws -> Int {
        var programs: [[SqlValue]] = []
        for service in services {
            for program in service.programs {
                let genres = program.genres.map { "\($0.level1).\($0.level2)" }.joined(separator: ",")
                programs.append([
                    .text(broadcasting), .integer(service.serviceID), .integer(program.eventID),
                    .integer(Int(program.start.timeIntervalSince1970)), .integer(Int(program.end.timeIntervalSince1970)),
                    .text(program.title), .text(program.summary), .text(program.extended),
                    SqlValue(program.genres.first?.level1), SqlValue(program.genres.first?.level2),
                    .text(genres), .integer(program.copyControl), .integer(program.parentalRating),
                    SqlValue(program.referenceServiceID), SqlValue(program.referenceEventID),
                    // a reference carries no text of its own, so it is searched through its parent
                    program.isReference
                        ? .null
                        : .text(Search.text(title: program.title, summary: program.summary,
                                            extended: program.extended)),
                ])
            }
        }
        let channels = services.enumerated().map { index, service in
            [SqlValue.text(broadcasting), .integer(service.serviceID), .text(service.name), .integer(index)]
        }

        return try db.transaction {
            try db.run("DELETE FROM programs WHERE bt=?", [.text(broadcasting)])
            try db.run("DELETE FROM channels WHERE bt=?", [.text(broadcasting)])
            try db.insertMany("INSERT INTO channels (bt, service_id, name, sort) VALUES (?,?,?,?)", channels)
            try db.insertMany("INSERT OR REPLACE INTO programs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", programs)
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                       [.text("epg_refreshed:\(broadcasting)"), .text(RecorderTime.format(now))])
            try noteAnswered(broadcasting: broadcasting, at: now)
            return programs.count
        }
    }

    /// Notes that the recorder was asked for one broadcasting type's guide and had none to give -- a model
    /// without that kind of tuner, or one not built yet -- so that the type is not asked for again on every
    /// connect until the recorder next rebuilds its files. What is cached for it is left as it is.
    public func noteNoGuide(broadcasting: String, at now: Date = Date()) throws {
        try noteAnswered(broadcasting: broadcasting, at: now)
    }

    private func noteAnswered(broadcasting: String, at now: Date) throws {
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                   [.text("epg_checked:\(broadcasting)"), .text(RecorderTime.format(now))])
    }

    /// Rewrites the search text of a cache written by an older build, once, from the text the cache already
    /// holds, and returns how many programmes it rewrote. The app asks for this in the background as soon as
    /// the cache is open, since a full guide takes a moment; a search asks as well, and waits for it, so that
    /// it does not miss the details. A failure leaves the mark unset, and the next search tries again.
    @discardableResult
    public func updateSearchText() throws -> Int {
        guard !searchTextIsCurrent else { return 0 }
        let stored = try db.query("SELECT value FROM meta WHERE key='search_text_version'") { $0.string("value") }
        if stored.first == Self.currentSearchTextVersion {
            searchTextIsCurrent = true
            return 0
        }
        var rewritten = 0
        // A broadcasting type at a time, so that the whole guide's text is never held at once. Each read is
        // inside its own write, so a refresh on another connection cannot slip in between the two.
        let types = try db.query("SELECT DISTINCT bt FROM programs") { $0.string("bt") }
        for broadcasting in types {
            rewritten += try db.transaction {
                let rows = try db.query("""
                SELECT rowid AS row, title, description, extended FROM programs
                WHERE bt=? AND ref_event_id IS NULL
                """, [.text(broadcasting)]) { row -> [SqlValue] in
                    [.text(Search.text(title: row.string("title"), summary: row.string("description"),
                                       extended: row.string("extended"))),
                     .integer(row.int("row"))]
                }
                try db.insertMany("UPDATE programs SET search_text=? WHERE rowid=?", rows)
                return rows.count
            }
        }
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('search_text_version', ?)",
                   [.text(Self.currentSearchTextVersion)])
        searchTextIsCurrent = true
        return rewritten
    }

    public func replaceLogos(_ logos: [StationLogo], broadcasting: String) throws {
        try replaceLogos(logos.map { (serviceID: $0.serviceID, channelNo: $0.channelNo, png: $0.png) },
                         broadcasting: broadcasting)
    }

    public func replaceLogos(_ logos: [(serviceID: Int, channelNo: Int, png: Data)], broadcasting: String) throws {
        try db.transaction {
            try db.run("DELETE FROM logos WHERE bt=?", [.text(broadcasting)])
            try db.insertMany("INSERT OR REPLACE INTO logos (bt, service_id, channel_no, png) VALUES (?,?,?,?)",
                              logos.map { [.text(broadcasting), .integer($0.serviceID), .integer($0.channelNo),
                                           .blob($0.png)] })
        }
    }

    // MARK: - channels

    /// Channels in the user's order when they set one, otherwise the recorder's.
    public func channels(broadcasting: String? = nil, includeHidden: Bool = false) throws -> [Channel] {
        var sql = """
        SELECT c.bt, c.service_id, c.name, c.sort, l.png AS logo, COALESCE(cp.hidden, 0) AS hidden, cp.position
        FROM channels c
        LEFT JOIN logos l ON l.bt=c.bt AND l.service_id=c.service_id
        LEFT JOIN channel_prefs cp ON cp.bt=c.bt AND cp.service_id=c.service_id
        """
        var conditions: [String] = []
        var values: [SqlValue] = []
        if let broadcasting {
            conditions.append("c.bt=?")
            values.append(.text(broadcasting))
        }
        if !includeHidden { conditions.append("COALESCE(cp.hidden, 0)=0") }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY c.bt, COALESCE(cp.position, 100000 + c.sort), c.sort"

        return try db.query(sql, values) { row in
            Channel(broadcasting: row.string("bt"), serviceID: row.int("service_id"), name: row.string("name"),
                    sort: row.int("sort"), hidden: row.int("hidden") == 1, position: row.optionalInt("position"),
                    logo: row.data("logo"))
        }
    }

    /// `order` is the service ids in the order wanted, an empty array puts them back in the recorder's order.
    /// `hidden` is the service ids to hide, an empty array shows everything. Passing nil leaves that alone.
    public func setChannelPreferences(broadcasting: String, order: [Int]? = nil, hidden: [Int]? = nil) throws {
        try db.transaction {
            let ids = try db.query("SELECT service_id FROM channels WHERE bt=?", [.text(broadcasting)]) {
                $0.int("service_id")
            }
            try db.insertMany("INSERT OR IGNORE INTO channel_prefs (bt, service_id) VALUES (?, ?)",
                              ids.map { [.text(broadcasting), .integer($0)] })
            if let order {
                let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
                try db.insertMany("UPDATE channel_prefs SET position=? WHERE bt=? AND service_id=?",
                                  ids.map { [SqlValue(positions[$0]), .text(broadcasting), .integer($0)] })
            }
            if let hidden {
                let hiddenIDs = Set(hidden)
                try db.insertMany("UPDATE channel_prefs SET hidden=? WHERE bt=? AND service_id=?",
                                  ids.map { [SqlValue(hiddenIDs.contains($0)), .text(broadcasting), .integer($0)] })
            }
        }
    }

    // MARK: - programmes

    /// A sub-channel's reference event has only times of its own, so the text comes from the programme on the
    /// parent service that it points at. That join is what the `r.` columns are for. `extra` adds columns
    /// after the programme's own.
    private static func selectPrograms(adding extra: String = "") -> String {
        """
        SELECT p.bt, p.service_id, c.name AS service_name, p.event_id, p.start, p.end,
               COALESCE(NULLIF(p.title,''), r.title, '') AS title,
               COALESCE(NULLIF(p.description,''), r.description, '') AS description,
               COALESCE(NULLIF(p.extended,''), r.extended, '') AS extended,
               COALESCE(NULLIF(p.genres,''), r.genres, '') AS genres,
               COALESCE(p.copy_control, r.copy_control, 0) AS copy_control,
               COALESCE(p.parental, r.parental, 0) AS parental,
               p.ref_service_id, p.ref_event_id\(extra)
        FROM programs p
        LEFT JOIN channels c ON c.bt=p.bt AND c.service_id=p.service_id
        LEFT JOIN channel_prefs cp ON cp.bt=p.bt AND cp.service_id=p.service_id
        LEFT JOIN programs r ON r.bt=p.bt AND r.service_id=p.ref_service_id AND r.event_id=p.ref_event_id
        """
    }

    /// The conditions every list of programmes can be narrowed by, as SQL and the values it binds, in order.
    private static func filters(broadcasting: String?, serviceID: Int? = nil, since: Date?, until: Date? = nil,
                                includeReferences: Bool, includeHidden: Bool) -> ([String], [SqlValue]) {
        var conditions: [String] = []
        var values: [SqlValue] = []
        if let broadcasting {
            conditions.append("p.bt=?")
            values.append(.text(broadcasting))
        }
        if let serviceID {
            conditions.append("p.service_id=?")
            values.append(.integer(serviceID))
        }
        if let since {
            conditions.append("p.end>?")
            values.append(.integer(Int(since.timeIntervalSince1970)))
        }
        if let until {
            conditions.append("p.start<?")
            values.append(.integer(Int(until.timeIntervalSince1970)))
        }
        if !includeReferences { conditions.append("p.ref_event_id IS NULL") }
        if !includeHidden { conditions.append("COALESCE(cp.hidden, 0)=0") }
        return (conditions, values)
    }

    public func programs(broadcasting: String? = nil, serviceID: Int? = nil, since: Date? = nil,
                         until: Date? = nil, includeReferences: Bool = false,
                         includeHidden: Bool = false, limit: Int = 500, offset: Int = 0) throws -> [GuideProgramRow] {
        var (conditions, values) = Self.filters(broadcasting: broadcasting, serviceID: serviceID, since: since,
                                                until: until, includeReferences: includeReferences,
                                                includeHidden: includeHidden)
        var sql = Self.selectPrograms()
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY p.start, p.bt, p.service_id LIMIT ? OFFSET ?"
        values += [.integer(limit), .integer(offset)]
        return try db.query(sql, values, Self.row)
    }

    /// Programmes whose title, description or details hold every word of `query`, found in those three in
    /// that order of preference and then by start time. At most `limit` of them; `more` says whether that
    /// left any out, which is found by asking for one more than that.
    ///
    /// The ranking is done here rather than on the rows that come back, so that the limit keeps the best of
    /// them: sorted by time alone, a common word would fill the list with the next two days' passing mentions
    /// in the details, and leave out the programme named for it on the fifth day.
    public func search(_ query: String, broadcasting: String? = nil, since: Date? = nil,
                       includeReferences: Bool = false, includeHidden: Bool = false,
                       limit: Int = 300) throws -> GuideSearchResults {
        let terms = Search.terms(query)
        guard !terms.isEmpty else { return GuideSearchResults() }
        // If it cannot be done now -- another connection writing, say -- the search goes on: the old text
        // still finds titles and descriptions, it only ranks everything as found in the details.
        _ = try? updateSearchText()

        // The search text is title, then summary, then details, with a different control character after
        // each of the first two, so where a word is first found says which field it is in. instr is plain
        // text, which is what the ranking wants; the LIKE that filters has its wildcards escaped instead.
        let text = "COALESCE(p.search_text, r.search_text, '')"
        let field = """
        CASE WHEN instr(\(text), ?) < instr(\(text), char(30)) THEN 0 \
        WHEN instr(\(text), ?) < instr(\(text), char(31)) THEN 1 ELSE 2 END
        """
        let fields = Array(repeating: field, count: terms.count)
        let match = terms.count == 1 ? field : "max(\(fields.joined(separator: ", ")))"
        var values = terms.flatMap { [SqlValue.text($0), .text($0)] }

        var (conditions, filterValues) = Self.filters(broadcasting: broadcasting, since: since,
                                                      includeReferences: includeReferences,
                                                      includeHidden: includeHidden)
        for term in terms {
            conditions.append("\(text) LIKE ? ESCAPE '\\'")
            filterValues.append(.text(Search.likePattern(term)))
        }
        values += filterValues
        var sql = Self.selectPrograms(adding: ", \(match) AS match")
        sql += " WHERE " + conditions.joined(separator: " AND ")
        sql += " ORDER BY match, p.start, p.bt, p.service_id LIMIT ?"
        values.append(.integer(limit + 1))

        let rows = try db.query(sql, values) { row in
            (program: Self.row(row), match: SearchMatch(rawValue: row.int("match")) ?? .extended)
        }
        let hits = rows.prefix(limit).map { row in
            GuideSearchHit(program: row.program, match: row.match,
                           snippet: row.match == .extended ? Self.snippet(for: terms, in: row.program) : nil)
        }
        return GuideSearchResults(hits: hits, more: rows.count > limit)
    }

    /// The words around the one that put a programme among the details-only results: the first word that is
    /// in neither its title nor its description, and so has to be in the details.
    private static func snippet(for terms: [String], in program: GuideProgramRow) -> Search.Snippet? {
        let title = Search.normalise(program.title)
        let summary = Search.normalise(program.summary)
        let term = terms.first { !title.contains($0) && !summary.contains($0) } ?? terms[0]
        return Search.snippet(of: term, in: program.extended)
    }

    /// Everything on one broadcast day for one broadcasting type, which is what a guide screen shows.
    public func day(_ day: Date, broadcasting: String, serviceID: Int? = nil,
                    includeHidden: Bool = false) throws -> [GuideProgramRow] {
        let range = dayRange(containing: day)
        return try programs(broadcasting: broadcasting, serviceID: serviceID, since: range.start,
                            until: range.end, includeHidden: includeHidden, limit: 5000)
    }

    public func program(broadcasting: String, serviceID: Int, eventID: Int) throws -> GuideProgramRow? {
        try db.query(Self.selectPrograms() + " WHERE p.bt=? AND p.service_id=? AND p.event_id=? ORDER BY p.start LIMIT 1",
                     [.text(broadcasting), .integer(serviceID), .integer(eventID)], Self.row).first
    }

    public func nowOnAir(broadcasting: String, at moment: Date = Date()) throws -> [GuideProgramRow] {
        let seconds = SqlValue.integer(Int(moment.timeIntervalSince1970))
        return try db.query(Self.selectPrograms() + " WHERE p.bt=? AND p.start<=? AND p.end>? ORDER BY c.sort",
                            [.text(broadcasting), seconds, seconds], Self.row)
    }

    /// Asked each time the day on screen changes. The count of programmes is answered from `ix_programs_ref`
    /// alone: without it SQLite read every programme of the type to count them, 11 ms a time on a Mac for a
    /// synthetic guide of 34,000 programmes, against 0.7 ms with it. The index is made by the schema script,
    /// so a cache from before it gets one when it is next opened.
    public func counts() throws -> [String: GuideCounts] {
        var out: [String: GuideCounts] = [:]
        for broadcasting in Codes.epgFiles.keys {
            let programs = try db.count("SELECT COUNT(*) FROM programs WHERE bt=? AND ref_event_id IS NULL",
                                        [.text(broadcasting)])
            let channels = try db.count("SELECT COUNT(*) FROM channels WHERE bt=?", [.text(broadcasting)])
            let refreshed = try meta("epg_refreshed:\(broadcasting)")
            let checked = try meta("epg_checked:\(broadcasting)")
            out[broadcasting] = GuideCounts(channels: channels, programs: programs, refreshed: refreshed,
                                            checked: checked)
        }
        return out
    }

    private func meta(_ key: String) throws -> String? {
        try db.query("SELECT value FROM meta WHERE key=?", [.text(key)]) { $0.string("value") }.first
    }

    // MARK: - reservations waiting for the recorder

    /// Adds one, or replaces the same programme queued before. Kept out of the tables the schema version
    /// throws away: this is the reader's, not a copy of the recorder's.
    public func queue(_ pending: PendingReservation) throws {
        try db.run("""
        INSERT OR REPLACE INTO pending_reservations
          (id, title, start, duration_sec, repeat_code, bt, service_id, service_name, quality_code, event_id,
           queued_at, problem)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """, values(for: pending))
    }

    /// Built a piece at a time: as one literal of twelve mixed values the type checker gives up.
    private func values(for pending: PendingReservation) -> [SqlValue] {
        let r = pending.request
        var out: [SqlValue] = [.text(pending.id), .text(r.title)]
        out.append(.integer(Int(r.start.timeIntervalSince1970)))
        out.append(.integer(r.durationSec))
        out.append(.text(r.repeatCode))
        out.append(.integer(r.broadcastingType))
        out.append(.integer(r.serviceID))
        out.append(.text(pending.serviceName))
        out.append(.integer(r.qualityCode))
        out.append(SqlValue(r.eventID))
        out.append(.integer(Int(pending.queuedAt.timeIntervalSince1970)))
        out.append(SqlValue(pending.problem))
        return out
    }

    public func pendingReservations() throws -> [PendingReservation] {
        try db.query("SELECT * FROM pending_reservations ORDER BY start") { row in
            let start = Date(timeIntervalSince1970: TimeInterval(row.int("start")))
            let queued = Date(timeIntervalSince1970: TimeInterval(row.int("queued_at")))
            let request = ReservationRequest(title: row.string("title"),
                                             start: start,
                                             durationSec: row.int("duration_sec"),
                                             repeatCode: row.string("repeat_code"),
                                             broadcastingType: row.int("bt"),
                                             serviceID: row.int("service_id"),
                                             qualityCode: row.int("quality_code"),
                                             eventID: row.optionalInt("event_id"))
            let problem = row.string("problem")
            return PendingReservation(request: request, serviceName: row.string("service_name"),
                                      queuedAt: queued, problem: problem.isEmpty ? nil : problem)
        }
    }

    public func removePending(_ id: String) throws {
        try db.run("DELETE FROM pending_reservations WHERE id = ?", [.text(id)])
    }

    /// Records why the recorder refused, so the row can say so instead of silently waiting for ever, and so
    /// that it is not sent again until the reader asks. nil clears it, which is that ask.
    public func setPendingProblem(_ id: String, _ problem: String?) throws {
        try db.run("UPDATE pending_reservations SET problem = ? WHERE id = ?",
                   [SqlValue(problem), .text(id)])
    }

    // MARK: - what a recording is about

    /// The recorder gives up a recording's programme text one recording at a time, so what it says is kept.
    /// This is not dropped when the guide's schema changes: it is slow to gather and never goes stale.
    public func titleSummary(_ id: String) throws -> String? {
        try db.query("SELECT summary FROM title_summaries WHERE id=?", [.text(id)]) { $0.string("summary") }
            .first
    }

    public func titleSummaries(_ ids: [String]) throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let places = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try db.query("SELECT id, summary FROM title_summaries WHERE id IN (\(places))",
                                ids.map { SqlValue.text($0) }) { ($0.string("id"), $0.string("summary")) }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    public func setTitleSummary(_ id: String, _ summary: String) throws {
        try db.run("INSERT OR REPLACE INTO title_summaries (id, summary, at) VALUES (?,?,?)",
                   [.text(id), .text(summary), .text(RecorderTime.format(Date()))])
    }

    /// Which of `titleKeys` the guide shows with the same programme text on two or more broadcast days. See
    /// `Duplicates.fixedBlurbs`.
    ///
    /// Only the programmes with one of those titles are kept from the query, so that the text of the whole
    /// guide -- thirty thousand programmes or more -- is neither held nor normalised; each title is looked at
    /// once, however often it is on.
    public func fixedBlurbs(among titleKeys: Set<String>) throws -> Set<Duplicates.Blurb> {
        guard !titleKeys.isEmpty else { return [] }
        var wanted: [String: Bool] = [:]
        let rows = try db.query("""
        SELECT title, description, start FROM programs WHERE ref_event_id IS NULL AND description<>''
        """) { row -> (title: String, summary: String, start: Date)? in
            let title = row.string("title")
            let keep = wanted[title] ?? titleKeys.contains(Series.sameTitleKey(title))
            wanted[title] = keep
            guard keep else { return nil }
            return (title, row.string("description"), Date(timeIntervalSince1970: TimeInterval(row.int("start"))))
        }
        return Duplicates.fixedBlurbs(in: rows.compactMap { $0 }, among: titleKeys)
    }

    // MARK: - time

    /// A broadcast day runs 04:00 to 04:00 in Japan, which is how the printed guides are laid out.
    private static let dayStartHour = 4

    /// The broadcast day named by the calendar date of `date`. The hour is taken on that date, so this
    /// names a day rather than finding the one on air: a moment just after midnight gives the day that
    /// starts at four that morning, not the one still going out. Pass a day from `broadcastDays`, which has
    /// already allowed for that.
    public nonisolated func dayRange(containing date: Date) -> (start: Date, end: Date) {
        Self.dayRange(containing: date)
    }

    public static func dayRange(containing date: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = dayStartHour
        components.minute = 0
        components.second = 0
        let start = calendar.date(from: components) ?? date
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400))
    }

    /// The broadcast day on air at `moment`, as midnight in Japan on the date it is named after, which is
    /// what `dayRange` takes. Until four in the morning the programmes going out still belong to the day
    /// before -- the late-night shows close the previous evening's guide -- so the date is read four hours
    /// back. Taking the calendar date instead left what is on after midnight in no day at all.
    public static func broadcastDay(containing moment: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        return calendar.startOfDay(for: moment.addingTimeInterval(-Double(dayStartHour) * 3600))
    }

    /// The days the recorder's guide covers, eight of them, starting with the broadcast day on air at `now`.
    public static func broadcastDays(from now: Date = Date(), count: Int = 8) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let first = broadcastDay(containing: now)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    // MARK: - rows

    private static func row(_ row: SqlRow) -> GuideProgramRow {
        let genres = row.string("genres").split(separator: ",").compactMap { pair -> Genre? in
            let levels = pair.split(separator: ".").compactMap { Int($0) }
            guard levels.count == 2 else { return nil }
            return Genre(level1: levels[0], level2: levels[1])
        }
        return GuideProgramRow(
            broadcasting: row.string("bt"),
            serviceID: row.int("service_id"),
            serviceName: row.string("service_name"),
            eventID: row.int("event_id"),
            start: Date(timeIntervalSince1970: TimeInterval(row.int("start"))),
            end: Date(timeIntervalSince1970: TimeInterval(row.int("end"))),
            title: row.string("title"),
            summary: row.string("description"),
            extended: row.string("extended"),
            genres: genres,
            copyControl: row.int("copy_control"),
            parental: row.int("parental"),
            isReference: row.optionalInt("ref_event_id") != nil,
            referenceServiceID: row.optionalInt("ref_service_id"),
            referenceEventID: row.optionalInt("ref_event_id")
        )
    }
}
