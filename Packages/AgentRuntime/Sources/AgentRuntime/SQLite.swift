import Foundation
import SQLite3

/// Minimal libsqlite3 wrapper (system library, no dependency). Not thread-safe by itself: owned by one actor.
final class SQLiteDB {
    enum Value { case text(String), int(Int64), real(Double), null }
    struct DBError: Error, CustomStringConvertible { let message: String; var description: String { message } }
    private var db: OpaquePointer?
    private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DBError(message: "open failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
    }
    deinit { sqlite3_close_v2(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "exec failed"; sqlite3_free(err); throw DBError(message: m)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Value] = []) throws -> Int {
        let stmt = try prepare(sql, args); defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError(message: String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ args: [Value] = []) throws -> [[String: Value]] {
        let stmt = try prepare(sql, args); defer { sqlite3_finalize(stmt) }
        var rows: [[String: Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError(message: String(cString: sqlite3_errmsg(db))) }
            var row: [String: Value] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, i))
                case SQLITE_NULL: row[name] = .null
                default: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let r = try body(); try exec("COMMIT"); return r } catch { try? exec("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DBError(message: "\(String(cString: sqlite3_errmsg(db))) in \(sql)") }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, TRANSIENT)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}

extension Dictionary where Key == String, Value == SQLiteDB.Value {
    func str(_ k: String) -> String? { if case .text(let s)? = self[k] { return s }; return nil }
    func int(_ k: String) -> Int64? { if case .int(let v)? = self[k] { return v }; return nil }
    func real(_ k: String) -> Double? { if case .real(let v)? = self[k] { return v }; if case .int(let v)? = self[k] { return Double(v) }; return nil }
    func date(_ k: String) -> Date? { real(k).map { Date(timeIntervalSince1970: $0) } }
}
