import Foundation
import Combine
import PlayerCore

@MainActor final class PlaybackPresentation: ObservableObject {
    // The playback clock only invalidates the progress view, not every button.
    let progress = PlaybackProgressPresentation()
    @Published var duration = 0.0
    @Published var paused = true
    @Published var speed = 1.0
    @Published var volume = 80.0
    @Published var ready = false
    @Published var previousEnabled = false
    @Published var nextEnabled = false
    @Published var loopEnabled = false
    func updatePosition(_ value: Double, immediate: Bool = false) {
        progress.updatePosition(value, immediate: immediate)
    }
    func updatePracticeAvailability(previous: Bool, next: Bool, loop: Bool) {
        if previousEnabled != previous { previousEnabled = previous }
        if nextEnabled != next { nextEnabled = next }
        if loopEnabled != loop { loopEnabled = loop }
    }
}
@MainActor final class PlaybackProgressPresentation: ObservableObject {
    @Published private(set) var position = 0.0
    private var publishedAt = 0.0
    func updatePosition(_ value: Double, immediate: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard value != position, immediate || now - publishedAt >= 0.1 else { return }
        publishedAt = now; position = value
    }
}
@MainActor final class SubtitlePresentation: ObservableObject {
    @Published var plain: [SubtitleCue] = []
    @Published var english: [SubtitleCue] = []
    @Published var chinese: [SubtitleCue] = []
    @Published var wordID: String?
    @Published var lockedWordID: String?
}
@MainActor final class LearningPresentation: ObservableObject {
    @Published var state = LearningState()
    @Published var entry: DictionaryEntry?
    @Published var status = ""
}

@MainActor final class MediaPresentation: ObservableObject {
    @Published var ready = false
    @Published var duration = 0.0
}
