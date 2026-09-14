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

public struct GuideCounts: Sendable, Equatable {
    public var channels: Int
    public var programs: Int
    /// When this broadcasting type was last refreshed, as the recorder's local time.
    public var refreshed: String?
}

/// The guide cache on the device: channels, programmes, station logos, and which channels the user hides or
/// reorders. The cache tables are disposable and are rebuilt when the schema changes; the user's own
/// preferences survive that.
public actor GuideStore {
    static let currentSchemaVersion = "1"

    private let db: Sqlite

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
    CREATE INDEX IF NOT EXISTS ix_programs_time ON programs (bt, service_id, start);
    CREATE INDEX IF NOT EXISTS ix_programs_start ON programs (bt, start);
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
            """)
            try db.execute(Self.schema)
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?)",
                       [.text(schemaVersion)])
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
                    program.isReference ? .null : .text(Search.normalise("\(program.title) \(program.summary)")),
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
            return programs.count
        }
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
    /// parent service that it points at. That join is what the `r.` columns are for.
    private static let selectPrograms = """
    SELECT p.bt, p.service_id, c.name AS service_name, p.event_id, p.start, p.end,
           COALESCE(NULLIF(p.title,''), r.title, '') AS title,
           COALESCE(NULLIF(p.description,''), r.description, '') AS description,
           COALESCE(NULLIF(p.extended,''), r.extended, '') AS extended,
           COALESCE(NULLIF(p.genres,''), r.genres, '') AS genres,
           COALESCE(p.copy_control, r.copy_control, 0) AS copy_control,
           COALESCE(p.parental, r.parental, 0) AS parental,
           p.ref_service_id, p.ref_event_id
    FROM programs p
    LEFT JOIN channels c ON c.bt=p.bt AND c.service_id=p.service_id
    LEFT JOIN channel_prefs cp ON cp.bt=p.bt AND cp.service_id=p.service_id
    LEFT JOIN programs r ON r.bt=p.bt AND r.service_id=p.ref_service_id AND r.event_id=p.ref_event_id
    """

    public func programs(broadcasting: String? = nil, serviceID: Int? = nil, since: Date? = nil,
                         until: Date? = nil, query: String? = nil, includeReferences: Bool = false,
                         includeHidden: Bool = false, limit: Int = 500, offset: Int = 0) throws -> [GuideProgramRow] {
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
        if let query, !query.isEmpty {
            conditions.append("COALESCE(p.search_text, r.search_text, '') LIKE ?")
            values.append(.text("%\(Search.normalise(query))%"))
        }
        if !includeReferences { conditions.append("p.ref_event_id IS NULL") }
        if !includeHidden { conditions.append("COALESCE(cp.hidden, 0)=0") }

        var sql = Self.selectPrograms
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY p.start, p.bt, p.service_id LIMIT ? OFFSET ?"
        values += [.integer(limit), .integer(offset)]
        return try db.query(sql, values, Self.row)
    }

    /// Everything on one broadcast day for one broadcasting type, which is what a guide screen shows.
    public func day(_ day: Date, broadcasting: String, serviceID: Int? = nil,
                    includeHidden: Bool = false) throws -> [GuideProgramRow] {
        let range = dayRange(containing: day)
        return try programs(broadcasting: broadcasting, serviceID: serviceID, since: range.start,
                            until: range.end, includeHidden: includeHidden, limit: 5000)
    }

    public func program(broadcasting: String, serviceID: Int, eventID: Int) throws -> GuideProgramRow? {
        try db.query(Self.selectPrograms + " WHERE p.bt=? AND p.service_id=? AND p.event_id=? ORDER BY p.start LIMIT 1",
                     [.text(broadcasting), .integer(serviceID), .integer(eventID)], Self.row).first
    }

    public func nowOnAir(broadcasting: String, at moment: Date = Date()) throws -> [GuideProgramRow] {
        let seconds = SqlValue.integer(Int(moment.timeIntervalSince1970))
        return try db.query(Self.selectPrograms + " WHERE p.bt=? AND p.start<=? AND p.end>? ORDER BY c.sort",
                            [.text(broadcasting), seconds, seconds], Self.row)
    }

    public func counts() throws -> [String: GuideCounts] {
        var out: [String: GuideCounts] = [:]
        for broadcasting in Codes.epgFiles.keys {
            let programs = try db.count("SELECT COUNT(*) FROM programs WHERE bt=? AND ref_event_id IS NULL",
                                        [.text(broadcasting)])
            let channels = try db.count("SELECT COUNT(*) FROM channels WHERE bt=?", [.text(broadcasting)])
            let refreshed = try db.query("SELECT value FROM meta WHERE key=?",
                                         [.text("epg_refreshed:\(broadcasting)")]) { $0.string("value") }.first
            out[broadcasting] = GuideCounts(channels: channels, programs: programs, refreshed: refreshed)
        }
        return out
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

    // MARK: - time

    /// A broadcast day runs 04:00 to 04:00 in Japan, which is how the printed guides are laid out. The hour is
    /// taken on the calendar day of `date`, so a moment just after midnight belongs to the day that is ending.
    public nonisolated func dayRange(containing date: Date) -> (start: Date, end: Date) {
        Self.dayRange(containing: date)
    }

    public static func dayRange(containing date: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 4
        components.minute = 0
        components.second = 0
        let start = calendar.date(from: components) ?? date
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400))
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
