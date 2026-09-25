import Testing
import Foundation
@testable import PlayerCore

final class SubtitleTests {
    @Test func testBilingualSRTKeepsIndependentLanguageTracks() throws {
        let input = "1\r\n00:00:01,250 --> 00:00:03,500\r\n<i>We can't give up.</i>\r\n我们不能放弃。\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\nKeep going!\r\n"
        let parsed = try SubtitleParser.parse(data: Data(input.utf8), ext: "srt")
        #expect(parsed.english.count == 2)
        #expect(parsed.chinese.count == 1)
        #expect(parsed.english[0].text == "We can't give up.")
        #expect(parsed.chinese[0].start == 1.25)
        #expect(parsed.english[0].tokens.filter(\.isWord).map(\.text) == ["We", "can't", "give", "up"])
    }
    @Test func testASSDialogueFormatCommasAndDrawing() throws {
        let ass = """
        [Script Info]
        Title: Fixture
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,{\\b1}Hello, world!{\\b0}\\N你好，世界！
        Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10
        """
        let parsed = try SubtitleParser.parse(data: Data(ass.utf8), ext: "ASS")
        #expect(parsed.english.map(\.text) == ["Hello, world!"])
        #expect(parsed.chinese.map(\.text) == ["你好，世界！"])
    }
    @Test func testVTTSettingsAndOptionalHours() throws {
        let text = "WEBVTT\n\nidentifier\n00:01.000 --> 00:03.100 align:start position:0%\n<c.green>Hello &amp; goodbye.</c>\n"
        let result = try SubtitleParser.parse(data: Data(text.utf8), ext: "vtt")
        #expect(result.english.first?.text == "Hello & goodbye.")
        #expect(result.english.first?.end == 3.1)
    }
    @Test func testUTF16AndMalformedIntervals() throws {
        let input = "1\n00:00:01,000 --> 00:00:02,000\n你好\n"
        let result = try SubtitleParser.parse(data: input.data(using: .utf16)!, ext: "srt")
        #expect(result.chinese.first?.text == "你好")
        #expect(throws: (any Error).self) { try SubtitleParser.parse(data: Data("1\n00:00:02,000 --> 00:00:01,000\nHello".utf8), ext: "srt") }
        #expect(SubtitleParser.timestamp("00:61:10") == nil)
    }
    @Test func testSentenceBoundaryAndOffsetAreHalfOpen() {
        let cues = [SubtitleCue(id: "1", start: 1, end: 2, text: "One"), SubtitleCue(id: "2", start: 2, end: 3, text: "Two")]
        #expect(Timeline.active(cues, at: 2).map(\.id) == ["2"])
        #expect(Timeline.active(cues, at: 2, offset: 0.5).map(\.id) == ["1"])
        #expect(Timeline.active(cues, at: 0.8).isEmpty)
    }
    @Test func testOverlappingCuesAreNotDropped() {
        let cues = [SubtitleCue(id: "1", start: 1, end: 5, text: "A"), SubtitleCue(id: "2", start: 2, end: 3, text: "B")]
        #expect(Timeline.active(cues, at: 2.5).map(\.id) == ["1", "2"])
    }
    @Test func testNoWordHighlightBeforeAlignmentOrDuringSilence() {
        #expect(Timeline.spoken([], at: 2) == nil)
        let word = TimedWord(cueID: "1", tokenIndex: 0, start: 1.3, end: 1.7)
        #expect(Timeline.spoken([word], at: 1.2) == nil)
        #expect(Timeline.spoken([word], at: 1.3) == word)
        #expect(Timeline.spoken([word], at: 1.7) == nil)
    }
    @Test func testBatchPrioritizesSeekAndSkipsCompletedCues() {
        let cues = (0..<20).map { SubtitleCue(id: String($0), start: Double($0 * 10), end: Double($0 * 10 + 5), text: "hello") }
        let batch = Timeline.nextBatch(cues, completed: ["10"], position: 100, offset: 0)
        #expect(batch.map(\.id) == ["11", "12", "13"])
        #expect(Timeline.nextBatch(cues, completed: [], position: 107, offset: 0).first?.id == "11")
        #expect(Timeline.nextBatch(cues, completed: [], position: 300, offset: 0).first?.id == "0")
    }
    @Test func testTokenizationPreservesOriginalTextAndContractions() {
        let input = "Well, don't re-enter John's well-known room!"
        let tokens = WordToken.tokenize(input)
        #expect(tokens.map(\.text).joined() == input)
        #expect(tokens.filter(\.isWord).map(\.text) == ["Well", "don't", "re-enter", "John's", "well-known", "room"])
        #expect(Set(tokens.map(\.id)).count == tokens.count)
    }
}
