import Testing
import Foundation
@testable import PlayerCore

struct PracticeTests {
    func cue(_ id: String, _ start: Double, _ end: Double, _ text: String) -> SubtitleCue { .init(id: id, start: start, end: end, text: text) }
    @Test func transcriptMatchesIndependentOffsetsAndKeepsUnmatchedChinese() {
        let english = [cue("a", 1, 3, "First."), cue("b", 3, 5, "Second.")]
        let chinese = [cue("z1", 0.5, 2.5, "第一句"), cue("z2", 2, 4, "跨句中文"), cue("z3", 7, 8, "额外中文")]
        let doc = TranscriptDocument(english: english, chinese: chinese, chineseOffset: 0.5)
        #expect(doc.rows.map(\.id) == ["en:a", "en:b", "zh:z3"])
        #expect(doc.rows[0].chinese.map(\.id) == ["z1", "z2"])
        #expect(doc.rows[1].chinese.map(\.id) == ["z2"])
        #expect(doc.rows[2].start == 7.5)
        #expect(doc.search("跨句").count == 2)
    }
    @Test func overlapIsHalfOpenAndNeverUsesLineNumbers() {
        let doc = TranscriptDocument(english: [cue("same-id", 5, 6, "Hello")], chinese: [cue("same-id", 0, 1, "无关"), cue("other", 4, 5, "相邻"), cue("match", 5.5, 7, "对应")])
        #expect(doc.rows.count == 3)
        #expect(doc.rows.last?.chinese.map(\.id) == ["match"])
        #expect(doc.rows.last?.english?.id == "same-id")
    }
    @Test func changingOffsetsRebuildsAssociationAndJumpPositions() {
        let en = [cue("a", 1, 2, "One")], zh = [cue("b", 3, 4, "一")]
        let before = TranscriptDocument(english: en, chinese: zh)
        let after = TranscriptDocument(english: en, chinese: zh, englishOffset: 2)
        #expect(before.rows.count == 2); #expect(after.rows.count == 1)
        #expect(after.rows[0].playbackStart == 3)
        #expect(after.rows[0].chineseText == "一")
    }
    @Test func chineseOnlyEnglishOnlyAndEmptyDocuments() {
        let zh = TranscriptDocument(chinese: [cue("a", 2, 3, "只有中文")])
        #expect(zh.rows[0].english == nil); #expect(zh.search("中文").count == 1)
        #expect(TranscriptDocument(english: [cue("a", 2, 3, "Only English")]).rows.count == 1)
        #expect(TranscriptDocument().anchorID(at: 1) == nil)
        #expect(TranscriptDocument().activeIDs(at: 1).isEmpty)
    }
    @Test func searchIsLiteralCaseInsensitiveAndRetainsPunctuation() {
        let doc = TranscriptDocument(english: [cue("a", 0, 1, "A [word]."), cue("b", 1, 2, "Another sentence")])
        #expect(doc.search(" WORD ").map(\.id) == ["en:a"])
        #expect(doc.search("[word]").count == 1)
        #expect(doc.search(".*").isEmpty)
        #expect(doc.search("  ").count == 2)
        #expect(doc.search("不存在").isEmpty)
    }
    @Test func activeRowsHandleLongOverlapsAndSilentGaps() {
        let doc = TranscriptDocument(english: [cue("long", 0, 20, "Long"), cue("short", 1, 2, "Short"), cue("later", 5, 6, "Later")])
        #expect(doc.activeIDs(at: 1.5) == ["en:long", "en:short"])
        #expect(doc.activeIDs(at: 2) == ["en:long"])
        #expect(doc.activeIDs(at: 5.5) == ["en:long", "en:later"])
        #expect(doc.activeIDs(at: 20).isEmpty)
        #expect(doc.anchorID(at: -1) == "en:long")
        #expect(doc.anchorID(at: 4) == "en:short")
    }
    @Test func bilingualParserFeedsTranscriptWithoutLosingTranslations() throws {
        let data = Data("1\n00:00:01,000 --> 00:00:02,000\nHello.\n你好。\n".utf8)
        let parsed = try SubtitleParser.parse(data: data, ext: "srt")
        let doc = TranscriptDocument(english: parsed.english, chinese: parsed.chinese)
        #expect(doc.rows.count == 1); #expect(doc.rows[0].chineseText == "你好。")
    }
    @Test func fiveThousandRowsSearchAndClockIndexRemainReusable() {
        let cues = (0..<5000).map { cue("\($0)", Double($0), Double($0) + 0.8, "Sentence \($0)") }
        let start = Date(); let doc = TranscriptDocument(english: cues)
        #expect(doc.rows.count == 5000)
        #expect(doc.search("sentence 4999").map(\.id) == ["en:4999"])
        for i in stride(from: 0, to: 5000, by: 13) { #expect(doc.activeIDs(at: Double(i) + 0.1) == ["en:\(i)"]) }
        #expect(Date().timeIntervalSince(start) < 2)
    }
    @Test func loopClipsToMediaBoundsAndRejectsOutOfRangeCues() throws {
        let first = try #require(SentenceLoop(cue: cue("a", 0.1, 2, "One"), offset: -0.5, duration: 4))
        #expect(first.start == 0); #expect(first.end == 1.5)
        let tail = try #require(SentenceLoop(cue: cue("b", 3, 6, "Tail"), offset: 0, duration: 4))
        #expect(tail.end == 4)
        #expect(SentenceLoop(cue: cue("c", 5, 6, "Past"), offset: 0, duration: 4) == nil)
        #expect(SentenceLoop(cue: cue("c", 1, 2, "Before"), offset: -3, duration: 4) == nil)
        #expect(SentenceLoop(cue: cue("c", 1, 2, "No media"), offset: 0, duration: 0) == nil)
    }
    @Test func shortLoopNeverCompletesAtItsOwnStart() throws {
        let loop = try #require(SentenceLoop(cue: cue("a", 1, 1.01, "Short"), offset: 0, duration: 2))
        #expect(!loop.reachedEnd(at: 1, eof: false))
        #expect(loop.reachedEnd(at: 1.01, eof: false))
        #expect(loop.reachedEnd(at: 1.005, eof: true))
    }
    @Test func advancedSubtitleCanReplayTheFullSpokenTailWithoutMovingItsStart() throws {
        let sentence = cue("reported", 5076.38, 5080.11, "So I'm backing out the door, right? And I got the TV like this.")
        let range = try #require(SentenceLoop(cue: sentence, offset: -1.7, duration: 8552.659, tailPadding: 0.8))
        #expect(abs(range.start - 5074.68) < 0.0001)
        #expect(abs(range.end - 5079.21) < 0.0001)
        #expect(!range.reachedEnd(at: 5078.41, eof: false))
        #expect(!range.reachedEnd(at: 5079.01, eof: false))
        #expect(!range.reachedEnd(at: range.end - 0.01, eof: false))
        #expect(range.reachedEnd(at: range.end, eof: false))
        #expect(sentence.end == 5080.11)
    }
    @Test func listeningTailIsBoundedAndCannotResurrectInvalidCues() throws {
        let sentence = cue("a", 1, 2, "One")
        #expect(SentenceLoop(cue: sentence, offset: 0, duration: 10, tailPadding: -1)?.end == 2)
        #expect(SentenceLoop(cue: sentence, offset: 0, duration: 10, tailPadding: 100)?.end == 5)
        #expect(SentenceLoop(cue: sentence, offset: 0, duration: 2.4, tailPadding: 0.8)?.end == 2.4)
        #expect(SentenceLoop(cue: sentence, offset: -3, duration: 10, tailPadding: 3) == nil)
        #expect(SentenceLoop(cue: cue("empty", 1, 1, ""), offset: 0, duration: 10, tailPadding: 0.8) == nil)
        #expect(SentenceLoop(cue: sentence, offset: .nan, duration: 10, tailPadding: 0.8) == nil)
        #expect(SentenceLoop(cue: sentence, offset: 0, duration: .infinity, tailPadding: 0.8) == nil)
        #expect(SentenceLoop.clampedTailPadding(.nan) == 0.8)
    }
    @Test func loopEOFIsConsumedAndCannotLeakIntoNormalPlayback() {
        let id = UUID(); var gate = PlaybackEndGate(); gate.begin(id, purpose: .sentenceLoop, playing: true)
        for _ in 0..<25 {
            #expect(gate.observe(generation: id, eof: false) == false)
            #expect(gate.observe(generation: id, eof: true) == false)
        }
        gate.purpose = .normal; gate.suppressCurrentEOF()
        #expect(gate.observe(generation: id, eof: true) == false)
        #expect(gate.observe(generation: UUID(), eof: false) == false)
        #expect(gate.observe(generation: id, eof: true) == false)
        #expect(gate.observe(generation: id, eof: false) == false)
        #expect(gate.observe(generation: id, eof: true) == true)
    }
    @Test func oldPreferencesKeepCustomBindingsOverNewDefaultsAndReportConflict() throws {
        // Exact v0.2 schema: no display mode or conflict notice fields.
        let data = Data(#"{"autoplay":false,"bindings":{"playPause":{"keyCode":15,"key":"r","modifiers":9},"forward":{"keyCode":11,"key":"b","modifiers":1}},"disabled":[]}"#.utf8)
        var prefs = try JSONDecoder().decode(InteractionPreferences.self, from: data)
        #expect(!prefs.autoplay); #expect(prefs.subtitleDisplay == .bilingual)
        #expect(prefs.shortcut(for: .playPause)?.matches(PlayerAction.toggleSentenceLoop.defaultShortcut) == true)
        #expect(prefs.shortcut(for: .forward)?.matches(PlayerAction.cycleSubtitleDisplay.defaultShortcut) == true)
        #expect(prefs.shortcut(for: .toggleSentenceLoop) == nil)
        #expect(prefs.shortcut(for: .cycleSubtitleDisplay) == nil)
        #expect(Set(prefs.conflictNotices) == ["toggleSentenceLoop", "cycleSubtitleDisplay"])
        #expect(prefs.assign(Shortcut(17, "t", .option), to: .toggleSentenceLoop) == nil)
        #expect(!prefs.conflictNotices.contains("toggleSentenceLoop"))
        #expect(try JSONDecoder().decode(InteractionPreferences.self, from: JSONEncoder().encode(prefs)) == prefs)
    }
    @Test func displayModeRoundTripsWithoutChangingQueueOrBindings() throws {
        var prefs = InteractionPreferences(); prefs.autoplay = false; prefs.subtitleDisplay = .hidden
        _ = prefs.assign(Shortcut(40, "k", .command), to: .playPause)
        let restored = try JSONDecoder().decode(InteractionPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(restored.subtitleDisplay == .hidden); #expect(!restored.autoplay)
        #expect(restored.shortcut(for: .playPause)?.key == "k")
        #expect(SubtitleDisplayMode.bilingual.next == .english)
        #expect(SubtitleDisplayMode.english.next == .hidden)
        #expect(SubtitleDisplayMode.hidden.next == .bilingual)
        #expect(try JSONDecoder().decode(InteractionPreferences.self, from: Data("{}".utf8)).subtitleDisplay == .bilingual)
    }
}
