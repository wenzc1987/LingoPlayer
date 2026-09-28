import Foundation
import CSQLite

public struct DatabaseError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// One instance belongs to one actor/queue; SQLite's FULLMUTEX is an additional guard.
public final class SQLiteStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw DatabaseError(message: "无法打开本地数据库。") }
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("CREATE TABLE IF NOT EXISTS playback (id TEXT PRIMARY KEY, json BLOB NOT NULL);")
        try execute("CREATE TABLE IF NOT EXISTS alignment (id TEXT PRIMARY KEY, json BLOB NOT NULL);")
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil)
        let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
        sqlite3_finalize(statement)
        if version < 2 {
            try execute("BEGIN IMMEDIATE;")
            do {
                try execute("CREATE TABLE IF NOT EXISTS queue (id TEXT PRIMARY KEY, json BLOB NOT NULL);")
                try execute("CREATE TABLE IF NOT EXISTS progress (id TEXT PRIMARY KEY, json BLOB NOT NULL);")
                try execute("PRAGMA user_version=2;")
                try execute("COMMIT;")
            } catch { try? execute("ROLLBACK;"); throw error }
        }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError(message: String(cString: sqlite3_errmsg(db))) }
    }
    public func save<T: Encodable>(_ value: T, key: String, table: String) throws {
        guard ["playback", "alignment", "queue", "progress"].contains(table) else { throw DatabaseError(message: "未知数据表。") }
        let data = try JSONEncoder().encode(value)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO \(table) (id,json) VALUES (?,?)", -1, &statement, nil) == SQLITE_OK else { throw DatabaseError(message: "无法保存缓存。") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError(message: String(cString: sqlite3_errmsg(db))) }
    }
    public func load<T: Decodable>(_ type: T.Type, key: String, table: String) throws -> T? {
        guard ["playback", "alignment", "queue", "progress"].contains(table) else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT json FROM \(table) WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw DatabaseError(message: "无法读取缓存。") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return try JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
}
