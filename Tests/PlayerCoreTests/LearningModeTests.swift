import Foundation
import Testing
@testable import PlayerCore

struct LearningModeTests {
    private func parse(_ text: String) throws -> ParsedSubtitles {
        try SubtitleParser.parse(data: Data("1\n00:00:01,000 --> 00:00:05,000\n\(text)\n".utf8), ext: "srt")
    }
    @Test func englishAndBilingualNeedActualLanguageEvidence() throws {
        let text = "I thought you were going to tell me what happened yesterday. We should talk about it before we leave the house."
        for input in [text, text + "\n出门之前我们应该谈一谈。"] {
            let parsed = try parse(input)
            #expect(parsed.assessment.isEnglish)
            #expect(parsed.assessment.confidence >= 0.85)
            #expect(parsed.english.count == 1)
            #expect(parsed.cues.first?.text == input)
        }
    }
    @Test(arguments: [
        "Hello, world!",
        "[The door slams loudly and footsteps echo down the empty hallway]",
        "(The audience applauds while dramatic music plays in the background)",
        "Je pensais que tu allais me raconter ce qui s'est passé hier. Nous devrions en parler avant de quitter la maison.",
        "Pensé que me ibas a contar lo que pasó ayer. Deberíamos hablar de ello antes de salir de casa.",
        "我以为你会告诉我昨天发生了什么，我们离开房子之前应该谈一谈。",
        "昨日何が起こったのか教えてくれると思っていました。家を出る前に話しましょう。"
    ]) func otherTextStaysReadableWithoutLearning(_ text: String) throws {
        let parsed = try parse(text)
        #expect(parsed.english.isEmpty)
        #expect(!parsed.assessment.isEnglish)
        #expect(parsed.cues.first?.text == text)
        let document = TranscriptDocument(cues: parsed.cues, offset: 2)
        #expect(document.rows.count == 1)
        #expect(document.rows[0].text == text && document.rows[0].english == nil)
        #expect(document.rows[0].playbackStart == 3)
        #expect(document.search(String(text.prefix(5))).count == 1)
    }
    @Test func aggregateSampleCanRecognizeManyShortCues() throws {
        let fragments = ["I thought", "you were going", "to tell me", "what happened", "yesterday.", "We should talk", "about it before", "we leave", "the house."]
        let cues = fragments.enumerated().map { SubtitleCue(id: String($0.offset), start: Double($0.offset), end: Double($0.offset + 1), text: $0.element) }
        #expect(SubtitleLanguageAssessment.assess(cues).isEnglish)
    }
    @Test func ordinaryBilingualCaptionsKeepSeparateOffsetsAndAllText() throws {
        let en = "I thought you were going to tell me what happened yesterday. We should talk about it before we leave the house."
        let parsed = try parse(en + "\n出门之前我们应该谈一谈。\n안녕하세요")
        #expect(parsed.assessment.isEnglish)
        #expect(parsed.primaryCues.first?.text == en + "\n안녕하세요")
        let document = TranscriptDocument(cues: parsed.primaryCues, offset: 1, secondary: parsed.chinese, secondaryOffset: 3)
        #expect(document.rows.count == 2)
        #expect(document.rows[0].start == 2 && document.rows[1].start == 4)
        #expect(document.search("안녕하세요").count == 1)
    }
    @Test func eligibilityRequiresReadyAndRealTimelineOverlap() {
        let cues = [SubtitleCue(id: "a", start: 10, end: 20, text: "Verified English")]
        #expect(!LearningModeRules.eligible(ready: false, duration: 30, english: cues, offset: 0))
        #expect(!LearningModeRules.eligible(ready: true, duration: 10, english: cues, offset: 0))
        #expect(!LearningModeRules.eligible(ready: true, duration: 30, english: cues, offset: -20))
        #expect(!LearningModeRules.eligible(ready: true, duration: .nan, english: cues, offset: 0))
        #expect(LearningModeRules.eligible(ready: true, duration: 11, english: cues, offset: 0))
        #expect(LearningModeRules.eligible(ready: true, duration: 10, english: cues, offset: -1))
    }
    @Test func soundEffectsCannotSupplyTheOnlyOverlappingEnglishInterval() throws {
        let data = Data("1\n00:00:01,000 --> 00:00:03,000\n[The door slams loudly]\n\n2\n01:00:00,000 --> 01:00:05,000\nI thought you were going to tell me what happened yesterday. We should talk about it before we leave the house.\n".utf8)
        let parsed = try SubtitleParser.parse(data: data, ext: "srt")
        #expect(parsed.cues.count == 2 && parsed.english.count == 1)
        #expect(!LearningModeRules.eligible(ready: true, duration: 30, english: parsed.english, offset: 0))
        #expect(SubtitleParser.timestamp("inf:00:00") == nil)
    }
    @Test func overrideNeverBypassesEligibilityAndWinsOverAutomaticCallbacks() {
        for policy in LearningActivationPolicy.allCases {
            #expect(!LearningModeRules.enabled(eligible: false, policy: policy, override: true))
            #expect(!LearningModeRules.enabled(eligible: true, policy: policy, override: false))
            #expect(LearningModeRules.enabled(eligible: true, policy: policy, override: true))
        }
        #expect(LearningModeRules.enabled(eligible: true, policy: .automatic, override: nil))
        #expect(!LearningModeRules.enabled(eligible: true, policy: .manual, override: nil))
    }
    @Test func newPlaybackPreferencesAreCompatibleAndPersisted() throws {
        let legacy = try JSONDecoder().decode(ViewingPreferences.self, from: Data("{}".utf8))
        #expect(legacy.seekPreviewEnabled && legacy.learningActivation == .automatic)
        for rate in [0.5, 2.0, 2.5, 3.0] {
            var value = legacy; value.speed = rate; value.seekPreviewEnabled = false; value.learningActivation = .manual
            let restored = try JSONDecoder().decode(ViewingPreferences.self, from: JSONEncoder().encode(value))
            #expect(restored.speed == rate && !restored.seekPreviewEnabled && restored.learningActivation == .manual)
        }
        let old = try JSONDecoder().decode(SavedPlayback.self, from: Data(#"{"englishPath":"/old.srt","englishOffset":1.2,"position":42}"#.utf8))
        #expect(old.primarySubtitlePath == nil && old.englishPath == "/old.srt" && old.englishOffset == 1.2 && old.position == 42)
    }
}
