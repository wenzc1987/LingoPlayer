import Foundation
import CSQLite

public protocol LearningContentProvider: Sendable {
    func lookup(_ word: String) async throws -> DictionaryEntry?
}

public actor ECDictionary: LearningContentProvider {
    private var db: OpaquePointer?
    public init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path), sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DatabaseError(message: "ECDICT 词库未就绪，请在设置中导入词库。")
        }
        var stmt: OpaquePointer?
        let code = sqlite3_prepare_v2(db, "SELECT word,phonetic,definition,translation,exchange FROM entries LIMIT 1", -1, &stmt, nil)
        sqlite3_finalize(stmt)
        guard code == SQLITE_OK else { throw DatabaseError(message: "词库格式不正确，请运行词库导入脚本。") }
    }
    deinit { sqlite3_close(db) }
    public func lookup(_ word: String) async throws -> DictionaryEntry? {
        let normalized = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if let exact = try query(normalized) { return exact }
        // Conservative fallback; dictionary-provided exchange data supplies irregular forms.
        let candidates: [String]
        if normalized.hasSuffix("ies") { candidates = [String(normalized.dropLast(3)) + "y"] }
        else if normalized.hasSuffix("ing") { let stem = String(normalized.dropLast(3)); candidates = [stem, stem + "e", undouble(stem)] }
        else if normalized.hasSuffix("ed") { let stem = String(normalized.dropLast(2)); candidates = [stem, stem + "e", undouble(stem)] }
        else if normalized.hasSuffix("s") { candidates = [String(normalized.dropLast()), String(normalized.dropLast(2))] }
        else { candidates = [] }
        for candidate in candidates where candidate.count > 1 {
            if let entry = try query(candidate) { return entry }
        }
        return nil
    }
    private func undouble(_ word: String) -> String {
        let chars = Array(word)
        return chars.count > 2 && chars.last == chars.dropLast().last ? String(word.dropLast()) : word
    }
    private func readError() -> DatabaseError {
        DatabaseError(message: "词库读取失败：" + String(cString: sqlite3_errmsg(db)))
    }
    private func query(_ word: String) throws -> DictionaryEntry? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT word,phonetic,definition,translation,exchange FROM entries WHERE word=? COLLATE NOCASE LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { throw readError() }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt, 1, word, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw readError() }
        switch sqlite3_step(stmt) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW: break
        default: throw readError()
        }
        func field(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0).replacingOccurrences(of: "\\n", with: "\n") } ?? "" }
        return DictionaryEntry(word: field(0), phonetic: field(1), definition: field(2), translation: field(3), exchange: field(4))
    }
}
