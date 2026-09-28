import Combine
import Testing
@testable import LingoPlayer

@MainActor struct PlaybackPresentationTests {
    @Test func clockUpdatesDoNotInvalidatePlaybackButtons() {
        let playback = PlaybackPresentation()
        var buttonUpdates = 0, positions: [Double] = []
        let buttons = playback.objectWillChange.sink { buttonUpdates += 1 }
        let clock = playback.progress.$position.dropFirst().sink { positions.append($0) }
        playback.updatePosition(8, immediate: true)
        playback.updatePosition(3, immediate: true) // Seek backwards.
        playback.updatePosition(0, immediate: true) // Open another video.
        #expect(positions == [8, 3, 0])
        #expect(playback.progress.position == 0)
        #expect(buttonUpdates == 0)
        withExtendedLifetime((buttons, clock)) {}
    }

    @Test func playbackActionsStillUpdateButtonsIndependentlyOfTheClock() {
        let playback = PlaybackPresentation()
        var buttonUpdates = 0, clockUpdates = 0
        let buttons = playback.objectWillChange.sink { buttonUpdates += 1 }
        let clock = playback.progress.objectWillChange.sink { clockUpdates += 1 }
        playback.paused = false; playback.volume = 30; playback.speed = 1.5
        playback.duration = 90; playback.ready = true
        #expect(buttonUpdates == 5 && clockUpdates == 0)
        withExtendedLifetime((buttons, clock)) {}
    }

    @Test func repeatedPositionsDoNotPublishAgain() {
        let playback = PlaybackPresentation()
        var updates = 0
        let clock = playback.progress.objectWillChange.sink { updates += 1 }
        playback.updatePosition(8, immediate: true)
        playback.updatePosition(8, immediate: true)
        playback.updatePosition(8)
        #expect(updates == 1)
        withExtendedLifetime(clock) {}
    }

    @Test func sentenceBoundariesUpdateButtonsOnlyWhenAvailabilityChanges() {
        let playback = PlaybackPresentation()
        var updates = 0
        let buttons = playback.objectWillChange.sink { updates += 1 }
        playback.updatePracticeAvailability(previous: false, next: true, loop: true)
        #expect(updates == 2)
        playback.updatePracticeAvailability(previous: false, next: true, loop: true)
        #expect(updates == 2)
        playback.updatePracticeAvailability(previous: true, next: false, loop: false)
        #expect(updates == 5)
        #expect(playback.previousEnabled && !playback.nextEnabled && !playback.loopEnabled)
        withExtendedLifetime(buttons) {}
    }
}
