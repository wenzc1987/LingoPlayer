import Foundation
import Testing
@testable import PlayerCore

struct WindowShortcutTests {
    @Test func oldPreferencesReceiveWindowShortcuts() throws {
        let preferences = try JSONDecoder().decode(InteractionPreferences.self, from: Data("{}".utf8))
        for action in [PlayerAction.toggleFullScreen, .toggleFitVideoWindow, .screenshot] {
            #expect(preferences.shortcut(for: action) == action.defaultShortcut)
        }
        #expect(!Shortcut(3, "f", [.control, .command]).isReserved)
        #expect(Shortcut(3, "f", .command).isReserved)
        #expect(Shortcut(3, "f", [.shift, .command]).isReserved)
    }
    @Test func existingCustomBindingsWinOverNewDefaults() throws {
        let data = Data(#"{"bindings":{"playPause":{"keyCode":11,"key":"b","modifiers":3},"replaySentence":{"keyCode":35,"key":"p","modifiers":3}}}"#.utf8)
        let preferences = try JSONDecoder().decode(InteractionPreferences.self, from: data)
        #expect(preferences.shortcut(for: .playPause) == PlayerAction.toggleFitVideoWindow.defaultShortcut)
        #expect(preferences.shortcut(for: .replaySentence) == PlayerAction.screenshot.defaultShortcut)
        #expect(preferences.shortcut(for: .toggleFitVideoWindow) == nil)
        #expect(preferences.shortcut(for: .screenshot) == nil)
        #expect(Set(preferences.conflictNotices) == Set([PlayerAction.toggleFitVideoWindow.rawValue, PlayerAction.screenshot.rawValue]))
    }
    @Test func windowBindingsCanBeChangedDisabledAndRestored() throws {
        var preferences = InteractionPreferences()
        for (action, code, key) in [(PlayerAction.toggleFullScreen, UInt16(22), "6"), (.toggleFitVideoWindow, 26, "7"), (.screenshot, 28, "8")] {
            let replacement = Shortcut(code, key, [.command, .option])
            #expect(preferences.assign(replacement, to: action) == nil)
            let roundTrip = try JSONDecoder().decode(InteractionPreferences.self, from: JSONEncoder().encode(preferences))
            #expect(roundTrip.shortcut(for: action) == replacement)
            #expect(preferences.assign(nil, to: action) == nil)
            #expect(try JSONDecoder().decode(InteractionPreferences.self, from: JSONEncoder().encode(preferences)).shortcut(for: action) == nil)
            #expect(preferences.assign(action.defaultShortcut, to: action) == nil)
        }
    }
}
