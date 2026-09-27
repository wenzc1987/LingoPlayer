import Foundation
import PlayerCore

@MainActor
extension AppModel {
    func refreshTranscript(reset: Bool = false) {
        transcript.rebuild(english: english, chinese: chinese, englishOffset: englishOffset, chineseOffset: chineseOffset, resetBrowsing: reset)
        transcript.updatePosition(position)
    }
    var currentLoopCandidate: SubtitleCue? {
        englishIndex.active(at: position - englishOffset).map { english[$0] }.first { loopRange(for: $0) != nil }
    }
    func loopRange(for cue: SubtitleCue) -> SentenceLoop? {
        guard playbackReady else { return nil }
        return SentenceLoop(cue: cue, offset: englishOffset, duration: duration)
    }
    func startSentenceLoop(_ cue: SubtitleCue) {
        guard let current = english.first(where: { $0.id == cue.id && $0 == cue }), let range = loopRange(for: current) else { return }
        replayRange = nil; replayArmed = false
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
    }
    func toggleSentenceLoop() {
        if sentenceLoop != nil { cancelSentenceLoop() }
        else if let cue = currentLoopCandidate { startSentenceLoop(cue) }
    }
    func navigateSentence(_ cue: SubtitleCue) {
        guard playbackReady, english.contains(cue), let range = loopRange(for: cue) else { return }
        let playing = endGate.wantsPlayback
        replayRange = nil; replayArmed = false; completed = false
        if sentenceLoop != nil { sentenceLoop = range; loopIterations = 0; endGate.purpose = .sentenceLoop }
        else { endGate.purpose = .normal }
        requestSeek(range.start); player.pause(!playing); paused = !playing
        aligner.updatePosition(range.start, seek: true); refreshLearning()
    }
    func navigateTranscript(_ row: TranscriptRow) {
        // Resolve against current content so an old native cell cannot navigate replaced subtitles.
        guard let current = transcript.document.rows.first(where: { $0.id == row.id }), current == row, canNavigateTranscript(current) else { return }
        if let cue = current.english { navigateSentence(cue) }
        else { seek(current.playbackStart) } // Chinese-only context has no English loop target.
    }
    func canNavigateTranscript(_ row: TranscriptRow) -> Bool {
        playbackReady && row.end > 0 && row.playbackStart < duration
    }
    func adjacentSentence(_ direction: Int) -> SubtitleCue? {
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
