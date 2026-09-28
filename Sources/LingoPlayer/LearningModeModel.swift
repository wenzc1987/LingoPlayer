import Foundation
import PlayerCore

@MainActor
extension AppModel {
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
            aligner.cancel(); lookupTask?.cancel(); lookupID = UUID()
            sentenceLoop = nil; cancelReplay(); practiceMessage = ""
            endGate.purpose = .normal
            timings = []; learning.reset(); learningPresentation.state = learningState
            currentWordID = nil; dictionaryEntry = nil; dictionary = nil; dictionaryConfigured = false; lastDictionaryKey = ""
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
