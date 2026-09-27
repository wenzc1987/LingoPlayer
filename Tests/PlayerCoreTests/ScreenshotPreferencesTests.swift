import Foundation
import Testing
@testable import PlayerCore

struct ScreenshotPreferencesTests {
    @Test func oldPreferencesKeepClipboardOnlyDefault() throws {
        let prefs = try JSONDecoder().decode(ViewingPreferences.self, from: Data(#"{"volume":37}"#.utf8))
        #expect(prefs.volume == 37)
        #expect(prefs.screenshot.clipboard && !prefs.screenshot.file && prefs.screenshot.directory.isEmpty)
    }
    @Test func destinationsAndDirectoryRoundTrip() throws {
        var preferences = ViewingPreferences()
        preferences.screenshot.clipboard = false; preferences.screenshot.file = true
        preferences.screenshot.directory = "/tmp/截图目录"
        #expect(try JSONDecoder().decode(ViewingPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
        preferences.screenshot.clipboard = true
        #expect(try JSONDecoder().decode(ViewingPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
    }
    @Test func invalidSettingsRecoverWithoutSilentlyEnablingFiles() throws {
        let value = try JSONDecoder().decode(ScreenshotPreferences.self, from: Data(#"{"clipboard":false,"file":false,"directory":42}"#.utf8))
        #expect(value.clipboard && !value.file && value.directory.isEmpty)
        let partial = try JSONDecoder().decode(ScreenshotPreferences.self, from: Data(#"{"file":"bad"}"#.utf8))
        #expect(partial.clipboard && !partial.file)
    }
    @Test func filenamesStayWithinDirectoryAndFilesystemLimits() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let name = ScreenshotPreferences.filename(title: "../A/B:C\\D\n", position: 3661.3, id: id)
        #expect(!name.contains("/") && !name.contains("\\") && !name.contains(":"))
        #expect(!name.hasPrefix(".") && name.contains("01-01-01") && name.hasSuffix(".png"))
        let long = ScreenshotPreferences.filename(title: String(repeating: "影片🎬", count: 200), position: .infinity)
        #expect(long.utf8.count < 255 && long.contains("00-00-00"))
        #expect(ScreenshotPreferences.filename(title: "", position: -1).hasPrefix("LingoPlayer-00-00-00"))
        #expect(ScreenshotPreferences.filename(title: "Film", position: 1) != ScreenshotPreferences.filename(title: "Film", position: 1))
    }
}
