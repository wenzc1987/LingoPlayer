import Testing
import Foundation
import CSQLite
@testable import PlayerCore

struct InteractionTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/lingoplayer-tests/\(name)") }
    @Test func queueBatchesSortNaturallyAndDeduplicateWithoutReorderingExisting() {
        var queue = PlaybackQueue()
        let first = queue.append([url("Episode10.mkv"), url("Episode2.mkv"), url("Episode1.mkv"), url("Episode2.mkv")])
        #expect(queue.items.map(\.name) == ["Episode1.mkv", "Episode2.mkv", "Episode10.mkv"])
        #expect(first.count == 3)
        queue.move(first[2], before: first[0])
        let second = queue.append([url("Episode2.mkv"), url("Episode3.mkv")])
        #expect(second.first == first[1])
        #expect(queue.items.map(\.name) == ["Episode10.mkv", "Episode1.mkv", "Episode2.mkv", "Episode3.mkv"])
    }
    @Test func removalUsesOriginalSuccessorAndNeverWraps() {
        var queue = PlaybackQueue(); let ids = queue.append([url("1.mp4"), url("2.mp4"), url("3.mp4")])
        queue.currentID = ids[1]
        queue.remove(ids[0]); #expect(queue.currentID == ids[1])
        #expect(queue.remove(ids[1]) == ids[2]); #expect(queue.currentID == ids[2])
        #expect(queue.adjacent(1) == nil)
        #expect(queue.remove(ids[2]) == nil); #expect(queue.currentID == nil)
    }
    @Test func queueMoveKeepsCurrentAndProgressSeparate() {
        var queue = PlaybackQueue(); let ids = queue.append([url("1.mp4"), url("2.mp4"), url("3.mp4")])
        queue.currentID = ids[0]; queue.move(ids[0], before: nil)
        #expect(queue.currentID == ids[0]); #expect(queue.currentIndex == 2)
        queue.mark(ids[1], failure: "Missing")
        #expect(queue.items[0].failure == "Missing")
        #expect(queue.adjacent(-1) == ids[2])
    }
    @Test func aliasesDeduplicate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.mp4"), alias = dir.appendingPathComponent("alias.mp4")
        try Data().write(to: real); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        var queue = PlaybackQueue(); queue.append([real, alias]); #expect(queue.items.count == 1)
    }
    @Test func shortcutsConflictUnbindRestoreAndPersist() throws {
        var prefs = InteractionPreferences()
        #expect(prefs.autoplay)
        #expect(prefs.assign(.playPauseDefault, to: .replaySentence)?.contains("播放") == true)
        #expect(prefs.shortcut(for: .replaySentence) == PlayerAction.replaySentence.defaultShortcut)
        #expect(prefs.assign(nil, to: .playPause) == nil)
        #expect(prefs.assign(.playPauseDefault, to: .replaySentence) == nil)
        #expect(prefs.assign(.playPauseDefault, to: .playPause) != nil)
        prefs.autoplay = false
        let restored = try JSONDecoder().decode(InteractionPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(restored == prefs); #expect(restored.shortcut(for: .playPause) == nil)
        prefs.resetAll(); #expect(prefs.shortcut(for: .playPause) != nil); #expect(!prefs.autoplay)
    }
    @Test func reservedKeysAndMissingPreferences() throws {
        var prefs = try JSONDecoder().decode(InteractionPreferences.self, from: Data("{}".utf8))
        #expect(prefs.autoplay)
        for (code, key) in [(UInt16(31), "o"), (8, "c"), (9, "v"), (43, ",")] {
            #expect(prefs.assign(Shortcut(code, key, .command), to: .playPause) != nil)
        }
        #expect(prefs.assign(Shortcut(48, "\t"), to: .playPause) != nil)
        #expect(prefs.assign(Shortcut(0, "a", .control), to: .playPause) != nil)
        #expect(prefs.shortcut(for: .playPause) == .playPauseDefault)
    }
    @Test func allDefaultsAreDistinctAndAllowed() {
        let values = PlayerAction.allCases.map(\.defaultShortcut)
        #expect(!values.contains { $0.isReserved })
        for (i, value) in values.enumerated() { #expect(!values.dropFirst(i + 1).contains { $0.matches(value) }) }
    }
    @Test func eofOnlyOnceAndOldGenerationCannotAdvance() {
        var gate = PlaybackEndGate(); let old = UUID(), current = UUID()
        gate.begin(current, purpose: .normal, playing: true)
        #expect(gate.observe(generation: old, eof: false) == false)
        #expect(gate.observe(generation: current, eof: true) == false) // no matching load/clear yet
        #expect(gate.observe(generation: current, eof: false) == false)
        #expect(gate.observe(generation: old, eof: true) == false)
        #expect(gate.observe(generation: current, eof: true) == true)
        #expect(gate.observe(generation: current, eof: true) == false)
    }
    @Test func replayRestorationAndPausedSeekNeverAdvanceAtEOF() {
        for purpose in [PlaybackPurpose.sentenceReplay, .restoration] {
            var gate = PlaybackEndGate(); let id = UUID(); gate.begin(id, purpose: purpose, playing: true)
            _ = gate.observe(generation: id, eof: false)
            #expect(gate.observe(generation: id, eof: true) == false)
            gate.purpose = .normal
            #expect(gate.observe(generation: id, eof: true) == false) // replay edge stays consumed
        }
        var gate = PlaybackEndGate(); let id = UUID(); gate.begin(id, purpose: .normal, playing: false)
        _ = gate.observe(generation: id, eof: false)
        #expect(gate.observe(generation: id, eof: true) == false)
    }
    @Test func sentencesRespectOffsetGapsBoundsAndOverlaps() {
        let cues = [SubtitleCue(id: "1", start: 1, end: 2, text: "One"), SubtitleCue(id: "2", start: 4, end: 6, text: "Two"), SubtitleCue(id: "3", start: 5, end: 7, text: "Three")]
        #expect(SentenceNavigation.target(cues: cues, position: 4, offset: 1, direction: -1) == 2) // gap
        #expect(SentenceNavigation.target(cues: cues, position: 4, offset: 1, direction: 1) == 5)
        #expect(SentenceNavigation.target(cues: cues, position: 5.02, offset: 1, direction: -1) == 2)
        #expect(SentenceNavigation.target(cues: cues, position: 6.5, offset: 1, direction: -1) == 5)
        #expect(SentenceNavigation.target(cues: cues, position: 2, offset: 1, direction: -1) == nil)
        #expect(SentenceNavigation.target(cues: cues, position: 8, offset: 1, direction: 1) == nil)
        #expect(SentenceNavigation.target(cues: [], position: 0, offset: 0, direction: 1) == nil)
    }
    @Test func v1DatabaseUpgradesWithoutLosingPlaybackOrAlignment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("library.sqlite")
        var db: OpaquePointer?; #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE playback (id TEXT PRIMARY KEY,json BLOB NOT NULL); CREATE TABLE alignment (id TEXT PRIMARY KEY,json BLOB NOT NULL); INSERT INTO playback VALUES ('old', '{\"position\":12,\"englishOffset\":0.5,\"chineseOffset\":0}'); INSERT INTO alignment VALUES ('cached','[]'); PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        do {
            let store = try SQLiteStore(url: path)
            let old = try store.load(SavedPlayback.self, key: "old", table: "playback")
            #expect(old?.position == 12); #expect(old?.englishOffset == 0.5)
            #expect(try store.load([TimedWord].self, key: "cached", table: "alignment") == [])
            var queue = PlaybackQueue(); queue.currentID = queue.append([url("movie.mp4")]).first
            try store.save(queue, key: "main", table: "queue")
            try store.save(PlaybackProgress(mediaKey: "movie", position: 12, duration: 60), key: "movie", table: "progress")
        }
        let reopened = try SQLiteStore(url: path)
        #expect(try reopened.load(PlaybackQueue.self, key: "main", table: "queue")?.items.count == 1)
        #expect(try reopened.load(PlaybackProgress.self, key: "movie", table: "progress")?.duration == 60)
        #expect(try reopened.load(SavedPlayback.self, key: "old", table: "playback")?.position == 12)
    }
}
private extension Shortcut { static var playPauseDefault: Self { PlayerAction.playPause.defaultShortcut } }
