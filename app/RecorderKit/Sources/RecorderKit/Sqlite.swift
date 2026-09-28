import Foundation
import SQLite3

/// A small wrapper over the SQLite that ships with the system, which keeps this package free of dependencies.
/// It is deliberately thin: the guide cache is written as SQL, the same SQL the server uses.
final class Sqlite {
    private let handle: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let code = handle.map { sqlite3_errcode($0) } ?? SQLITE_CANTOPEN
            if let handle { sqlite3_close_v2(handle) }
            throw SqliteError.open(path: path, code: code)
        }
        self.handle = handle
        // The overnight run and the screens each open the file for themselves, and in the same process when
        // the system wakes the app for the one while the reader has the other open. Without a wait, whichever
        // wrote second failed at once with "database is locked" -- and a reservation already sent whose row
        // then could not be removed from the queue was sent again the next time. Five seconds is several times
        // longer than any write here has been seen to take on a Mac.
        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    static let busyTimeoutMilliseconds: Int32 = 5000

    deinit { sqlite3_close_v2(handle) }

    /// Runs one or more statements, for schema scripts and pragmas.
    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        guard code == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? lastError
            sqlite3_free(message)
            throw SqliteError.statement(sql: String(sql.prefix(200)), code: code, message: detail)
        }
    }

    func run(_ sql: String, _ values: [SqlValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        while try statement.step() {}
    }

    func query<T>(_ sql: String, _ values: [SqlValue] = [], _ row: (SqlRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(values)
        var out: [T] = []
        while try statement.step() {
            out.append(try row(statement))
        }
        return out
    }

    func count(_ sql: String, _ values: [SqlValue] = []) throws -> Int {
        try query(sql, values) { $0.int(at: 0) }.first ?? 0
    }

    /// All or nothing. A failure rolls back, so a half-written guide refresh cannot be left behind.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs one statement once per row, preparing it a single time.
    func insertMany(_ sql: String, _ rows: [[SqlValue]]) throws {
        guard !rows.isEmpty else { return }
        let statement = try prepare(sql)
        for row in rows {
            statement.reset()
            try statement.bind(row)
            while try statement.step() {}
        }
    }

    func prepare(_ sql: String) throws -> SqlStatement {
        try SqlStatement(database: handle, sql: sql)
    }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }
}

/// What went wrong with the database on the phone, with SQLite's result code kept, since that is what says
/// what can be done about it: a full disk is the reader's to put right, and the text SQLite gives for it --
/// "database or disk is full: INSERT OR REPLACE INTO programs ..." -- is English and says nothing they can use.
public enum SqliteError: Error, CustomStringConvertible, Sendable {
    case open(path: String, code: Int32)
    case statement(sql: String, code: Int32, message: String)

    /// The result code as SQLite gave it, which may be an extended one.
    public var code: Int32 {
        switch self {
        case .open(_, let code), .statement(_, let code, _): code
        }
    }

    /// The primary result code, which is what the explanation goes by: `SQLITE_IOERR_WRITE` is an
    /// `SQLITE_IOERR`, and an extended code is only returned when asked for.
    public var primaryCode: Int32 { code & 0xFF }

    /// What to put in front of the reader: Japanese, as the rest of the app's text is, with the code at the end
    /// so that a report of it can be looked up.
    public var explanation: String {
        let reason = switch primaryCode {
        case SQLITE_FULL:
            "iPhone の空き容量が足りないため、端末内のデータベースに書き込めませんでした。"
                + "空き容量を増やしてから、もう一度お試しください"
        case SQLITE_BUSY, SQLITE_LOCKED:
            "端末内のデータベースがほかの処理で使われていました。しばらくしてから、もう一度お試しください"
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            "端末内のデータベースが壊れています"
        case SQLITE_IOERR:
            "端末内のデータベースの読み書きに失敗しました"
        case SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_READONLY, SQLITE_AUTH:
            "端末内のデータベースを開けませんでした"
        case SQLITE_NOMEM:
            "メモリが足りないため、端末内のデータベースを読み書きできませんでした"
        default:
            "端末内のデータベースでエラーが起きました"
        }
        return "\(reason) (SQLite \(code))"
    }

    /// The same with the statement and SQLite's own words, for a log.
    public var detail: String {
        switch self {
        case .open(let path, _): "\(explanation) \(path)"
        case .statement(let sql, _, let message): "\(explanation) \(message): \(sql)"
        }
    }

    /// The explanation, since this is what the screens show when they put an error into words: every place
    /// that says why the cache could not be read or a reservation could not be kept interpolates the error.
    public var description: String { explanation }
}

/// A value to bind. The literal conformances let call sites read like the SQL they belong to.
public enum SqlValue: Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral,
                      ExpressibleByBooleanLiteral {
    case null
    case integer(Int)
    case text(String)
    case blob(Data)

    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .integer(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .integer(value ? 1 : 0) }

    public init(_ value: Int?) { self = value.map { .integer($0) } ?? .null }
    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    public init(_ value: Bool) { self = .integer(value ? 1 : 0) }
}

public protocol SqlRow {
    func int(at index: Int32) -> Int
    func int(_ column: String) -> Int
    func optionalInt(_ column: String) -> Int?
    func string(_ column: String) -> String
    func data(_ column: String) -> Data?
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SqlStatement: SqlRow {
    private let handle: OpaquePointer
    private let indexes: [String: Int32]

    init(database: OpaquePointer, sql: String) throws {
        var handle: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &handle, nil)
        guard code == SQLITE_OK, let handle else {
            let message = String(cString: sqlite3_errmsg(database))
            if let handle { sqlite3_finalize(handle) }
            throw SqliteError.statement(sql: String(sql.prefix(200)), code: code, message: message)
        }
        self.handle = handle
        var indexes: [String: Int32] = [:]
        for index in 0..<sqlite3_column_count(handle) {
            if let name = sqlite3_column_name(handle, index) {
                indexes[String(cString: name)] = index
            }
        }
        self.indexes = indexes
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [SqlValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null: status = sqlite3_bind_null(handle, index)
            case .integer(let number): status = sqlite3_bind_int64(handle, index, Int64(number))
            case .text(let text): status = sqlite3_bind_text(handle, index, text, -1, sqliteTransient)
            case .blob(let data):
                status = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
            }
            guard status == SQLITE_OK else {
                throw SqliteError.statement(sql: "bind \(index)", code: status, message: "could not bind value")
            }
        }
    }

    /// True while there is a row to read.
    func step() throws -> Bool {
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw SqliteError.statement(sql: String(cString: sqlite3_sql(handle)), code: code,
                                        message: String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
        }
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func int(at index: Int32) -> Int { Int(sqlite3_column_int64(handle, index)) }

    func int(_ column: String) -> Int {
        guard let index = indexes[column] else { return 0 }
        return Int(sqlite3_column_int64(handle, index))
    }

    func optionalInt(_ column: String) -> Int? {
        guard let index = indexes[column], sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(handle, index))
    }

    func string(_ column: String) -> String {
        guard let index = indexes[column], let text = sqlite3_column_text(handle, index) else { return "" }
        return String(cString: text)
    }

    func data(_ column: String) -> Data? {
        guard let index = indexes[column], let bytes = sqlite3_column_blob(handle, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, index)))
    }
}
