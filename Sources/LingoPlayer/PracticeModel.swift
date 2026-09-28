import Foundation
import PlayerCore

@MainActor
extension AppModel {
    var practicedCue: SubtitleCue? {
        replayCue ?? sentenceLoop.flatMap { loop in english.first { $0.id == loop.cueID } }
    }
    func refreshTranscript(reset: Bool = false) {
        updateLearningMode()
        transcript.rebuild(english: english, chinese: chinese, englishOffset: englishOffset, chineseOffset: chineseOffset, resetBrowsing: reset, plain: isLearningMode ? nil : displaySubtitles)
        transcript.updatePosition(position)
    }
    var currentLoopCandidate: SubtitleCue? {
        if let cue = practicedCue, loopRange(for: cue) != nil { return cue }
        return englishIndex.active(at: position - englishOffset).map { english[$0] }.first { loopRange(for: $0) != nil }
    }
    func loopRange(for cue: SubtitleCue) -> SentenceLoop? {
        guard isLearningMode, playbackReady else { return nil }
        return SentenceLoop(cue: cue, offset: englishOffset, duration: duration, tailPadding: sentenceTailPadding)
    }
    func startSentenceLoop(_ cue: SubtitleCue) {
        guard let current = english.first(where: { $0.id == cue.id && $0 == cue }), let range = loopRange(for: current) else { return }
        cancelReplay()
        sentenceLoop = range; loopIterations = 0; practiceMessage = ""
        endGate.purpose = .sentenceLoop; endGate.wantsPlayback = true; completed = false
        requestSeek(range.start); paused = false; player.pause(false)
        aligner.updatePosition(range.start, seek: true); refreshLearning()
    }
    func cancelSentenceLoop() {
        guard sentenceLoop != nil else { return }
        sentenceLoop = nil; practiceMessage = ""
        if endGate.purpose == .sentenceLoop { endGate.purpose = .normal }
        endGate.suppressCurrentEOF()
        seekRevision &+= 1; player.synchronize(revision: seekRevision)
        refreshLearning()
    }
    func toggleSentenceLoop() {
        if sentenceLoop != nil { cancelSentenceLoop() }
        else if let cue = currentLoopCandidate { startSentenceLoop(cue) }
    }
    func navigateSentence(_ cue: SubtitleCue) {
        guard playbackReady, english.contains(cue), let range = loopRange(for: cue) else { return }
        let playing = endGate.wantsPlayback
        cancelReplay(); completed = false
        if sentenceLoop != nil { sentenceLoop = range; loopIterations = 0; endGate.purpose = .sentenceLoop }
        else { endGate.purpose = .normal }
        requestSeek(range.start); player.pause(!playing); paused = !playing
        aligner.updatePosition(range.start, seek: true); refreshLearning()
    }
    func navigateTranscript(_ row: TranscriptRow) {
        // Resolve against current content so an old native cell cannot navigate replaced subtitles.
        guard let current = transcript.document.rows.first(where: { $0.id == row.id }), current == row, canNavigateTranscript(current) else { return }
        if isLearningMode, let cue = current.english { navigateSentence(cue) }
        else { seek(current.playbackStart) } // Chinese-only context has no English loop target.
    }
    func canNavigateTranscript(_ row: TranscriptRow) -> Bool {
        playbackReady && row.end > 0 && row.playbackStart < duration
    }
    func adjacentSentence(_ direction: Int) -> SubtitleCue? {
        guard isLearningMode else { return nil }
        // Tail playback may already pass the next subtitle's start. Navigation
        // must still be relative to the sentence the learner is practicing.
        if let cue = practicedCue, let current = english.firstIndex(of: cue) {
            let next = current + (direction > 0 ? 1 : -1)
            return english.indices.contains(next) ? english[next] : nil
        }
        guard let index = englishIndex.adjacent(at: position - englishOffset, direction: direction) else { return nil }
        return english[index]
    }
    func navigateAdjacentSentence(_ direction: Int) {
        guard let cue = adjacentSentence(direction), loopRange(for: cue) != nil else { return }
        navigateSentence(cue)
    }
    func setSubtitleDisplay(_ mode: SubtitleDisplayMode) {
        var updated = preferences; updated.subtitleDisplay = mode; updatePreferences(updated)
    }
}
