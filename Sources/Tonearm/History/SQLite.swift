import Foundation
import SQLite3

/// A thin wrapper over the system SQLite. Not thread safe: `HistoryStore` uses one
/// connection from one serial queue.
enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)

    var description: String {
        switch self {
        case .open(let m): return "could not open the history database: \(m)"
        case .prepare(let m): return "history database error: \(m)"
        case .step(let m): return "history database error: \(m)"
        }
    }
}

enum SQLValue {
    case int(Int64)
    case text(String)
    case null

    /// Optional values: nil binds NULL.
    static func of(_ v: Int64?) -> SQLValue { v.map { .int($0) } ?? .null }
    static func of(_ v: Bool?) -> SQLValue { v.map { .int($0 ? 1 : 0) } ?? .null }
    static func of(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
}

/// SQLite copies the bytes of bound text before the call returns.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDB {
    let handle: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close_v2(db)
            throw SQLiteError.open(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
    }

    deinit { sqlite3_close_v2(handle) }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// Rows inserted, changed or deleted on this connection since it opened.
    var totalChanges: Int { Int(sqlite3_total_changes(handle)) }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw SQLiteError.step(message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement { try SQLiteStatement(db: self, sql: sql) }

    /// The first column of the first row, or nil.
    func int(_ sql: String, _ values: [SQLValue] = []) throws -> Int64? {
        let s = try prepare(sql)
        s.bind(values)
        return try s.step() ? s.optionalInt(0) : nil
    }

    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let s = try prepare(sql)
        try s.run(values)
    }

    /// Runs `body` in a transaction; rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class SQLiteStatement {
    let db: SQLiteDB
    let stmt: OpaquePointer

    init(db: SQLiteDB, sql: String) throws {
        self.db = db
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw SQLiteError.prepare("\(db.errorMessage) in \(sql)")
        }
        stmt = s
    }

    deinit { sqlite3_finalize(stmt) }

    /// Resets the statement and binds `values` to ?1, ?2, ...
    func bind(_ values: [SQLValue]) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(stmt, index, v)
            case .text(let v): sqlite3_bind_text(stmt, index, v, -1, sqliteTransient)
            case .null: sqlite3_bind_null(stmt, index)
            }
        }
    }

    /// True when a row is ready, false when done.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError.step(db.errorMessage)
        }
    }

    /// Binds and steps until done.
    func run(_ values: [SQLValue]) throws {
        bind(values)
        while try step() {}
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }

    func optionalInt(_ column: Int32) -> Int64? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, column)
    }

    func text(_ column: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: p)
    }

    func optionalText(_ column: Int32) -> String? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : text(column)
    }
}
