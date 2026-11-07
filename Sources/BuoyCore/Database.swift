import Foundation
import SQLite3

public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

public protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension UUID: SQLBindable { public var sqlValue: SQLValue { .text(uuidString) } }
extension LocalDate: SQLBindable { public var sqlValue: SQLValue { .text(iso) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public struct DatabaseError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

public struct Row {
    fileprivate var values: [String: SQLValue]

    public subscript(_ column: String) -> SQLValue { values[column] ?? .null }

    public func string(_ c: String) -> String? {
        switch self[c] {
        case .text(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .null: nil
        }
    }
    public func int(_ c: String) -> Int? {
        switch self[c] {
        case .int(let i): Int(i)
        case .double(let d): Int(d)
        case .text(let s): Int(s)
        case .null: nil
        }
    }
    public func double(_ c: String) -> Double? {
        switch self[c] {
        case .int(let i): Double(i)
        case .double(let d): d
        case .text(let s): Double(s)
        case .null: nil
        }
    }
    public func date(_ c: String) -> Date? { double(c).map(Date.init(timeIntervalSince1970:)) }
    public func uuid(_ c: String) -> UUID? { string(c).flatMap(UUID.init(uuidString:)) }
    public func localDate(_ c: String) -> LocalDate? { string(c).flatMap(LocalDate.init(iso:)) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal wrapper over the system SQLite library.
public final class Database {
    public let path: String
    fileprivate let handle: OpaquePointer

    public init(path: String, readOnly: Bool = false, wal: Bool = true) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(db)
            throw DatabaseError(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA foreign_keys = ON")
        if !readOnly && wal {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
        }
    }

    deinit { sqlite3_close_v2(handle) }

    private func error(_ rc: Int32) -> DatabaseError {
        DatabaseError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one or more SQL statements with no parameters.
    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw DatabaseError(code: rc, message: message)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ args: SQLBindable...) throws -> Int {
        try run(sql, args)
    }

    @discardableResult
    public func run(_ sql: String, _ args: [SQLBindable]) throws -> Int {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ args: SQLBindable...) throws -> [Row] {
        try query(sql, args)
    }

    public func query(_ sql: String, _ args: [SQLBindable]) throws -> [Row] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        let columns = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var values: [String: SQLValue] = [:]
            for i in 0..<columns {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB: values[name] = .null
                default: values[name] = .null
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    private func prepare(_ sql: String, _ args: [SQLBindable]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        for (offset, arg) in args.enumerated() {
            let index = Int32(offset + 1)
            let bindRC: Int32
            switch arg.sqlValue {
            case .null: bindRC = sqlite3_bind_null(stmt, index)
            case .int(let v): bindRC = sqlite3_bind_int64(stmt, index, v)
            case .double(let v): bindRC = sqlite3_bind_double(stmt, index, v)
            case .text(let v): bindRC = sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            }
            if bindRC != SQLITE_OK {
                sqlite3_finalize(stmt)
                throw error(bindRC)
            }
        }
        return stmt
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
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

    public var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?.int("user_version")) ?? 0 }
    }

    public func setUserVersion(_ v: Int) throws {
        try execute("PRAGMA user_version = \(v)")
    }

    /// Copies the entire contents of `source` into this database using SQLite's
    /// online backup API. Used for restore.
    public func replaceContents(with source: Database) throws {
        guard let backup = sqlite3_backup_init(handle, "main", source.handle, "main") else {
            throw error(sqlite3_errcode(handle))
        }
        let stepRC = sqlite3_backup_step(backup, -1)
        let finishRC = sqlite3_backup_finish(backup)
        guard stepRC == SQLITE_DONE else { throw error(stepRC) }
        guard finishRC == SQLITE_OK else { throw error(finishRC) }
    }

    /// Writes a compact, self-contained copy of the database to `url`.
    public func writeCopy(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try run("VACUUM INTO ?", url.path)
        // Make the copy a single self-contained file (no -wal / -shm companions).
        let copy = try Database(path: url.path, wal: false)
        try copy.execute("PRAGMA journal_mode = DELETE")
    }
}
