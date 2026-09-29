import Foundation
import PlayerCore

@MainActor
extension AppModel {
    var highlightedLearningSelection: LearningSelection? {
        guard isLearningMode, let spoken = learning.spoken, spoken.token.isWord,
              currentWordID == "\(spoken.cue.id):\(spoken.token.id)" else { return nil }
        return spoken
    }
    func adjacentLockedWord(_ direction: Int) -> LearningSelection? {
        guard isLearningMode, !preferences.cardHidden else { return nil }
        return learning.locked?.adjacentWord(direction)
    }
    func moveLockedWord(_ direction: Int) {
        guard let next = adjacentLockedWord(direction) else { return }
        // Browsing the card neither seeks nor interrupts playback or replay.
        revealLearningCard(); learning.lock(next); refreshDictionary()
    }
    func playbackPreferencesChanged() {
        seekPreview.setEnabled(viewing.seekPreviewEnabled)
        if appliedLearningPolicy != viewing.learningActivation {
            appliedLearningPolicy = viewing.learningActivation
            learningOverride = nil
            updateLearningMode()
        }
    }
    func chooseLearningMode(_ enabled: Bool) {
        guard !enabled || learningEligible else { return }
        learningOverride = enabled
        updateLearningMode()
    }
    func updateLearningMode() {
        let eligible = LearningModeRules.eligible(ready: playbackReady, duration: duration, english: english, offset: englishOffset)
        if learningEligible != eligible { learningEligible = eligible }
        let enabled = LearningModeRules.enabled(eligible: eligible, policy: viewing.learningActivation, override: learningOverride)
        guard enabled != isLearningMode else { return }
        isLearningMode = enabled
        if enabled {
            restartAlignment()
        } else {
            // Invalidate every learning producer before clearing its presentation.
            // None of these operations seeks or changes the playback intent.
            aligner.cancel(); dictionaryLookup.reset()
            sentenceLoop = nil; cancelReplay(); practiceMessage = ""
            endGate.purpose = .normal
            timings = []; learning.reset(); learningPresentation.state = learningState
            currentWordID = nil
            alignmentTaskStatus = AlignmentTaskStatus(.idle, "")
            alignmentStatus = ""; showAlignmentDetails = false; alignmentDetails = ""
            chrome.resetNotice()
            if isDetached { onReattach?(); isDetached = false }
            if sidebarTab == .learning { sidebarTab = .transcript }
        }
        refreshTranscript(); refreshLearning(); updateSubtitleStatus()
        onShortcutsChanged?()
    }
}
