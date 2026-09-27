import Foundation
import PlayerCore

/// Runs only inside the isolated native practice regression, using the real mpv clock.
@MainActor enum ReplayTailSmoke {
    static func run(_ model: AppModel) async -> [[String: Any]] {
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail])
        }
        func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline { if condition() { return true }; try? await Task.sleep(nanoseconds: 10_000_000) }
            return condition()
        }
        let originalEnglish = model.english, originalChinese = model.chinese
        let originalOffset = model.englishOffset, originalChineseOffset = model.chineseOffset
        let originalPadding = model.sentenceTailPadding
        let cue = SubtitleCue(id: "tail-regression", start: 3, end: 4, text: "Finish this.")
        let next = SubtitleCue(id: "early-next", start: 4.2, end: 5.2, text: "Next sentence.")
        model.english = [cue, next]; model.chinese = []
        model.setOffset(-1.7, language: .english); model.setSentenceTailPadding(0.8)
        model.seek(1.5)
        _ = await wait { model.seekTarget == nil }
        model.aligner.cancel(); await model.aligner.waitForCancellation()
        // The next subtitle starts early, while the practiced phrase is still audible.
        // Put its timing first to ensure it cannot steal the practiced word highlight.
        model.timings = [TimedWord(cueID: next.id, tokenIndex: 0, start: 2.5, end: 3),
                         TimedWord(cueID: cue.id, tokenIndex: 2, start: 2.6, end: 2.9)]
        let knownTimings = model.timings
        model.lock(cue: cue, token: cue.tokens[0]); model.replaySentence()
        record("negative_offset_replay_keeps_start_and_extends_tail", abs((model.replayRange?.lowerBound ?? 0) - 1.3) < 0.001 && abs((model.replayRange?.upperBound ?? 0) - 3.1) < 0.001)
        let reachedTail = await wait { model.position >= 2.65 || model.replayRange == nil }
        record("replay_still_plays_and_highlights_its_own_cue_after_subtitle_end", reachedTail && !model.paused && model.replayRange != nil && model.activeEnglish == [cue] && model.currentWordID == "\(cue.id):2", "position=\(model.position), word=\(model.currentWordID ?? "nil")")
        let finished = await wait { model.replayRange == nil && model.paused }
        record("replay_pauses_after_full_tail_and_keeps_practiced_subtitle", finished && model.position >= 3.1 && model.position < 3.4 && model.activeEnglish == [cue] && model.selected?.cue == cue, "position=\(model.position)")
        record("navigation_and_loop_target_stay_on_practiced_sentence_after_tail", model.adjacentSentence(1) == next && model.adjacentSentence(-1) == nil && model.currentLoopCandidate == cue)
        model.setSentenceTailPadding(1.2)
        record("tail_adjustment_preserves_offsets_and_alignment", model.englishOffset == -1.7 && model.timings == knownTimings && abs((model.loopRange(for: cue)?.end ?? 0) - 3.5) < 0.001)
        await model.store?.flush()
        if let key = model.media?.key, let restored = try? await model.store?.load(SavedPlayback.self, key: key, table: "playback") {
            record("tail_setting_persists_per_media_with_existing_offset", restored.sentenceTailPadding == 1.2 && restored.englishOffset == -1.7)
        } else { record("tail_setting_persists_per_media_with_existing_offset", false) }
        model.resumeLearning()
        record("continue_learning_releases_practiced_subtitle", model.replayCue == nil && model.activeEnglish == [next] && !model.learning.isLocked)
        model.togglePlayback(); _ = await wait { model.paused }
        model.setSentenceTailPadding(0); model.lock(cue: cue, token: cue.tokens[0]); model.replaySentence()
        record("zero_tail_restores_subtitle_endpoint", abs((model.replayRange?.upperBound ?? 0) - 2.3) < 0.001)
        model.seek(3.2)
        record("direct_seek_clears_replay_subtitle", model.replayCue == nil && model.replayRange == nil && model.activeEnglish == [next])
        if model.endGate.wantsPlayback { model.togglePlayback() }
        _ = await wait { model.paused && model.seekTarget == nil }
        model.english = originalEnglish; model.chinese = originalChinese
        model.setOffset(originalOffset, language: .english); model.setOffset(originalChineseOffset, language: .chinese)
        model.setSentenceTailPadding(originalPadding)
        return checks
    }
}
