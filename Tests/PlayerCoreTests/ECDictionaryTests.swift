import Foundation
import CSQLite
import Testing
@testable import PlayerCore

struct ECDictionaryTests {
    @Test func databaseReadFailureIsNotAnUnknownWord() async throws {
        let fixture = try DictionaryFixture()
        let dictionary = try ECDictionary(path: fixture.url.path)
        try fixture.execute("DROP TABLE entries")
        do {
            _ = try await dictionary.lookup("read")
            Issue.record("A database error must be reported, not cached as an unknown word")
        } catch is DatabaseError { }
    }

    @Test func exactFormsFallbacksAndMissingWordsRemainDistinct() async throws {
        let fixture = try DictionaryFixture()
        let dictionary = try ECDictionary(path: fixture.url.path)
        #expect(try await dictionary.lookup("READ")?.word == "read")
        #expect(try await dictionary.lookup("read")?.translation == "读取\n阅读")
        #expect(try await dictionary.lookup("running")?.word == "run")
        #expect(try await dictionary.lookup("stories")?.word == "story")
        #expect(try await dictionary.lookup("don’t")?.word == "don't")
        #expect(try await dictionary.lookup("unknown") == nil)
    }
}

private final class DictionaryFixture {
    let folder: URL
    let url: URL
    private var database: OpaquePointer?
    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        url = folder.appendingPathComponent("dictionary.sqlite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw DatabaseError(message: "fixture open failed") }
        try execute("""
        CREATE TABLE entries (word TEXT PRIMARY KEY COLLATE NOCASE, phonetic TEXT, definition TEXT, translation TEXT, exchange TEXT);
        INSERT INTO entries VALUES ('read','','','读取\\n阅读',''), ('run','','','',''), ('story','','','',''), ('don''t','','','','');
        """)
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError(message: "fixture SQL failed") }
    }
    deinit { sqlite3_close(database); try? FileManager.default.removeItem(at: folder) }
}
