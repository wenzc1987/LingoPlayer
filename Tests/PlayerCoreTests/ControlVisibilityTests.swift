import Testing
import Foundation
@testable import PlayerCore

struct ControlVisibilityTests {
    @Test func playingHidesAfterThreeSecondsAndRepeatedSnapshotsDoNotPostponeIt() {
        var state = ControlVisibility()
        state.playback(paused: false, ready: true, now: 10)
        state.playback(paused: false, ready: true, now: 12)
        state.expire(now: 12.99); #expect(state.visible)
        state.expire(now: 13); #expect(!state.visible)
        state.toggle(now: 20); #expect(state.visible && state.deadline == 23)
    }
    @Test func pauseRevealsControlsButAllowsManualHidingUntilPlaybackChanges() {
        var state = ControlVisibility()
        state.playback(paused: false, ready: true, now: 0); state.expire(now: 3)
        state.playback(paused: true, ready: true, now: 4)
        #expect(state.visible && state.deadline == nil)
        state.toggle(now: 5); state.playback(paused: true, ready: true, now: 6)
        #expect(!state.visible)
        state.playback(paused: false, ready: true, now: 7)
        #expect(state.visible && state.deadline == 10)
    }
    @Test func holdsNestAndRestartTheDeadlineOnlyWhenAllAreReleased() {
        var state = ControlVisibility()
        state.playback(paused: false, ready: true, now: 0)
        state.hold(.pointer, active: true, now: 1)
        state.hold(.presentation, active: true, now: 2)
        state.hold(.pointer, active: false, now: 3)
        state.expire(now: 100); #expect(state.visible && state.deadline == nil)
        state.toggle(now: 100); #expect(state.visible)
        state.hold(.presentation, active: false, now: 101)
        #expect(state.deadline == 104)
    }
    @Test func draggingAndKeyboardNavigationProtectControlsAndLoadingNeverAutoHides() {
        for reason in [ControlVisibility.Hold.scrubbing, .keyboard, .windowButtons] {
            var state = ControlVisibility()
            state.playback(paused: false, ready: true, now: 0)
            state.hold(reason, active: true, now: 1); state.expire(now: 50)
            #expect(state.visible && state.deadline == nil)
            state.hold(reason, active: false, now: 51); state.expire(now: 54)
            #expect(!state.visible)
            state.playback(paused: false, ready: false, now: 55); state.expire(now: 99)
            #expect(state.visible && state.deadline == nil)
        }
    }
    @Test func sidebarDefaultsAreCollapsedButExplicitLegacyPreferenceSurvives() throws {
        #expect(InteractionPreferences().sidebarCollapsed)
        #expect(try JSONDecoder().decode(InteractionPreferences.self, from: Data("{}".utf8)).sidebarCollapsed)
        let legacy = try JSONDecoder().decode(InteractionPreferences.self, from: Data(#"{"sidebarCollapsed":false,"cardHidden":true}"#.utf8))
        #expect(!legacy.sidebarCollapsed && legacy.cardHidden)
    }
}
