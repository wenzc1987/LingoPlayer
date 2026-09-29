import Foundation
import Testing
@testable import PlayerCore

struct ViewingPreferencesTests {
    @Test func missingAndPartialPreferencesPreserveDefaults() throws {
        let empty = try JSONDecoder().decode(ViewingPreferences.self, from: Data("{}".utf8))
        #expect(empty == ViewingPreferences())
        let partial = try JSONDecoder().decode(ViewingPreferences.self, from: Data(#"{"volume":0,"subtitles":{"englishSize":30}}"#.utf8))
        #expect(partial.volume == 0 && partial.speed == 1)
        #expect(partial.subtitles.englishSize == 30 && partial.subtitles.chineseSize == 15)
        #expect(partial.subtitles.bottomInset == 24 && partial.subtitles.backgroundOpacity == 0.38)
    }
    @Test func invalidFieldsCannotBreakLayoutOrDiscardValidPreferences() throws {
        let raw = #"{"volume":-100,"speed":50,"windowSize":{"width":10,"height":99999},"subtitles":{"englishSize":999,"chineseSize":"bad","backgroundOpacity":-1,"bottomInset":1000},"linkedSubtitleOffsets":true}"#
        let value = try JSONDecoder().decode(ViewingPreferences.self, from: Data(raw.utf8))
        #expect(value.volume == 0 && value.speed == 3)
        #expect(value.windowSize.width == 240 && value.windowSize.height == 4320)
        #expect(value.subtitles.englishSize == 36 && value.subtitles.chineseSize == 15)
        #expect(value.subtitles.backgroundOpacity == 0 && value.subtitles.bottomInset == 160)
        #expect(value.linkedSubtitleOffsets)
        let unsafe = SubtitleAppearance(englishSize: .infinity, chineseSize: .nan, backgroundOpacity: .nan, bottomInset: .infinity)
        #expect(unsafe == SubtitleAppearance())
    }
    @Test func preferencesRoundTripWithoutLosingMuteOrAppearance() throws {
        var value = ViewingPreferences()
        value.volume = 0; value.speed = 1.5; value.linkedSubtitleOffsets = true; value.fitVideoWindow = true
        value.windowSize = PlayerWindowSize(width: 1100, height: 720)
        value.subtitles = SubtitleAppearance(englishSize: 31, chineseSize: 22, backgroundOpacity: 0.6, bottomInset: 80)
        let decoded = try JSONDecoder().decode(ViewingPreferences.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }
    @Test func pauseSelectionDefaultsOnAndPersistsAnExplicitOff() throws {
        for raw in ["{}", #"{"selectWordOnPause":"invalid","volume":25}"#] {
            let value = try JSONDecoder().decode(ViewingPreferences.self, from: Data(raw.utf8))
            #expect(value.selectWordOnPause)
        }
        var value = ViewingPreferences(); value.selectWordOnPause = false
        let restored = try JSONDecoder().decode(ViewingPreferences.self, from: JSONEncoder().encode(value))
        #expect(!restored.selectWordOnPause && restored == value)
    }
}
