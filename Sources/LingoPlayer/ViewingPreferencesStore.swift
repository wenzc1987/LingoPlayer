import Foundation
import Combine
import PlayerCore

@MainActor final class ViewingPreferencesStore: ObservableObject {
    @Published private(set) var subtitles: SubtitleAppearance
    @Published private(set) var linkedSubtitleOffsets: Bool
    @Published private(set) var fitVideoWindow: Bool
    @Published private(set) var screenshot: ScreenshotPreferences
    var onWindowModeChanged: (() -> Void)?
    private var values: ViewingPreferences
    private let storage: StorageWorker
    static var url: URL { RuntimeSettings.supportDirectory.appendingPathComponent("viewing.json") }
    var volume: Double { values.volume }
    var speed: Double { values.speed }
    var windowSize: PlayerWindowSize { values.windowSize }

    init(storage: StorageWorker) {
        self.storage = storage
        let loaded = (try? Data(contentsOf: Self.url)).flatMap { try? JSONDecoder().decode(ViewingPreferences.self, from: $0) } ?? ViewingPreferences()
        values = loaded; subtitles = loaded.subtitles; linkedSubtitleOffsets = loaded.linkedSubtitleOffsets; fitVideoWindow = loaded.fitVideoWindow
        screenshot = loaded.screenshot
    }
    private func update(_ change: (inout ViewingPreferences) -> Void) {
        var next = values; change(&next); next.normalize()
        guard next != values else { return }
        values = next
        // Audio and window changes do not invalidate subtitle layout.
        if subtitles != next.subtitles { subtitles = next.subtitles }
        if linkedSubtitleOffsets != next.linkedSubtitleOffsets { linkedSubtitleOffsets = next.linkedSubtitleOffsets }
        let windowModeChanged = fitVideoWindow != next.fitVideoWindow
        if windowModeChanged { fitVideoWindow = next.fitVideoWindow }
        if screenshot != next.screenshot { screenshot = next.screenshot }
        storage.write(next, to: Self.url)
        if windowModeChanged { onWindowModeChanged?() }
    }
    func setVolume(_ value: Double) { update { $0.volume = value } }
    func setSpeed(_ value: Double) { update { $0.speed = value } }
    func setWindowSize(_ value: PlayerWindowSize) { update { $0.windowSize = value } }
    func setSubtitles(_ value: SubtitleAppearance) { update { $0.subtitles = value } }
    func setLinkedOffsets(_ value: Bool) { update { $0.linkedSubtitleOffsets = value } }
    func setFitVideoWindow(_ value: Bool) { update { $0.fitVideoWindow = value } }
    func setScreenshot(_ value: ScreenshotPreferences) { update { $0.screenshot = value } }
}
