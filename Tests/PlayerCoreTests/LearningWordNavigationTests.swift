import Foundation
import Testing
@testable import PlayerCore

struct LearningWordNavigationTests {
    @Test func repeatedWordsSkipPunctuationAndKeepLockedContext() throws {
        let cue = SubtitleCue(id: "locked", start: 10, end: 16, text: "Help, help! Don't stop now.")
        let words = cue.tokens.filter(\.isWord)
        var selection = LearningSelection(cue: cue, token: words[0], chinese: "帮帮忙，别停。", offset: 0.75)
        #expect(selection.adjacentWord(-1) == nil)
        for word in words.dropFirst() {
            selection = try #require(selection.adjacentWord(1))
            #expect(selection.token == word && selection.cue == cue)
            #expect(selection.chinese == "帮帮忙，别停。" && selection.playbackStart == 10.75 && selection.playbackEnd == 16.75)
        }
        #expect(selection.adjacentWord(1) == nil)
        for word in words.dropLast().reversed() {
            selection = try #require(selection.adjacentWord(-1))
            #expect(selection.token == word)
        }
        #expect(selection.adjacentWord(-1) == nil)
    }
    @Test func singleWordAndInvalidSelectionCannotMove() {
        let cue = SubtitleCue(id: "single", start: 1, end: 2, text: "...Hello!")
        let selection = LearningSelection(cue: cue, token: cue.tokens.first(where: \.isWord)!, chinese: "", offset: 0)
        for direction in [-2, -1, 0, 1, 2] { #expect(selection.adjacentWord(direction) == nil) }
        let invalid = LearningSelection(cue: cue, token: .init(id: 999, text: "missing", isWord: true), chinese: "", offset: 0)
        #expect(invalid.adjacentWord(-1) == nil && invalid.adjacentWord(1) == nil)
    }
    @Test func existingCustomCommandArrowsWinOnUpgrade() throws {
        let raw = #"{"bindings":{"screenshot":{"keyCode":123,"key":"←","modifiers":1},"toggleFitVideoWindow":{"keyCode":124,"key":"→","modifiers":1}}}"#
        let preferences = try JSONDecoder().decode(InteractionPreferences.self, from: Data(raw.utf8))
        #expect(preferences.shortcut(for: .screenshot) == PlayerAction.previousWord.defaultShortcut)
        #expect(preferences.shortcut(for: .toggleFitVideoWindow) == PlayerAction.nextWord.defaultShortcut)
        #expect(preferences.shortcut(for: .previousWord) == nil && preferences.shortcut(for: .nextWord) == nil)
        #expect(Set(preferences.conflictNotices) == Set([PlayerAction.previousWord.rawValue, PlayerAction.nextWord.rawValue]))
        let roundTrip = try JSONDecoder().decode(InteractionPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(roundTrip == preferences)
    }
}
