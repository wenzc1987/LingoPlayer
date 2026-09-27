import Testing
import Foundation
@testable import PlayerCore

final class StateAndStorageTests {
    private func selection(_ text: String, id: String) -> LearningSelection {
        let cue = SubtitleCue(id: id, start: 1, end: 2, text: text)
        return LearningSelection(cue: cue, token: cue.tokens[0], chinese: "示例", offset: 0.5)
    }
    @Test func testLockedWordSurvivesNewSpeechAndSilentGaps() {
        let first = selection("Hello", id: "1"), second = selection("World", id: "2")
        var state = LearningState()
        state.follow(first); state.lock(first); state.follow(second)
        #expect(state.selected == first)
        #expect(state.spoken == second)
        state.follow(nil)
        #expect(state.selected == first)
        #expect(state.isLocked)
    }
    @Test func testResumeFollowsCurrentWordAndMediaResetClearsLock() {
        let first = selection("Hello", id: "1"), second = selection("World", id: "2")
        var state = LearningState()
        state.lock(first); state.follow(second); state.resumeFollowing()
        #expect(state.selected == second)
        #expect(!(state.isLocked))
        state.lock(first); state.reset()
        #expect(state.selected == nil)
    }
    @Test func testLearningSelectionPreservesReplayBoundsAndContext() {
        let value = selection("Hello", id: "1")
        #expect(value.playbackStart == 1.5)
        #expect(value.playbackEnd == 2.5)
        #expect(value.chinese == "示例")
    }
    @Test func testOldPlaybackKeepsOffsetsAndPositionWhenTailSettingIsAdded() throws {
        let data = Data(#"{"position":5076.029,"englishOffset":-1.7,"chineseOffset":-1.7,"audioStream":1,"englishPath":"/movie.ass"}"#.utf8)
        var restored = try JSONDecoder().decode(SavedPlayback.self, from: data)
        #expect(restored.position == 5076.029)
        #expect(restored.englishOffset == -1.7 && restored.chineseOffset == -1.7)
        #expect(restored.englishPath == "/movie.ass" && restored.audioStream == 1)
        #expect(restored.sentenceTailPadding == 0.8)
        restored.sentenceTailPadding = 1.2
        #expect(try JSONDecoder().decode(SavedPlayback.self, from: JSONEncoder().encode(restored)).sentenceTailPadding == 1.2)
    }
    @Test func testSQLiteSurvivesReopenAndKeepsAlignmentKeysSeparate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        var saved = SavedPlayback(); saved.position = 17.4; saved.englishOffset = -0.25; saved.englishPath = "/movie/sub's.srt"; saved.sentenceTailPadding = 1.1
        do {
            let store = try SQLiteStore(url: url)
            try store.save(saved, key: "media'1", table: "playback")
            try store.save([TimedWord(cueID: "1", tokenIndex: 0, start: 1, end: 2)], key: "audio1-sub1", table: "alignment")
        }
        let store = try SQLiteStore(url: url)
        let restored = try #require(try store.load(SavedPlayback.self, key: "media'1", table: "playback"))
        #expect(restored.position == 17.4)
        #expect(restored.englishPath == saved.englishPath)
        #expect(restored.englishOffset == -0.25)
        #expect(restored.sentenceTailPadding == 1.1)
        #expect(try store.load([TimedWord].self, key: "audio2-sub1", table: "alignment") == nil)
        #expect(try store.load([TimedWord].self, key: "audio1-sub1", table: "alignment")?.count == 1)
        #expect(throws: (any Error).self) { try store.save(saved, key: "key", table: "playback; DROP TABLE playback") }
    }
    @Test func testDictionaryLemmaUsesExplicitExchange() {
        let entry = DictionaryEntry(word: "went", exchange: "0:go/p:went/d:gone")
        #expect(entry.lemma == "go")
        #expect(DictionaryEntry(word: "story").lemma == nil)
    }
    @Test func testMissingDictionaryFailsWithActionableError() {
        #expect(throws: (any Error).self) { try ECDictionary(path: "/nonexistent/ecdict.sqlite") }
    }
    @Test func testDifferentSubtitleContentHasDifferentDigest() {
        #expect(Digest.string("same file, revised text") != Digest.string("same file, original text"))
        #expect(Digest.string("stable") == Digest.string("stable"))
    }
}
