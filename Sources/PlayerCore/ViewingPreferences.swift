import Foundation

private func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}

public struct SubtitleAppearance: Codable, Equatable {
    public var englishSize: Double
    public var chineseSize: Double
    public var backgroundOpacity: Double
    public var bottomInset: Double
    public init(englishSize: Double = 23, chineseSize: Double = 15, backgroundOpacity: Double = 0.38, bottomInset: Double = 24) {
        self.englishSize = bounded(englishSize, 16...36, fallback: 23)
        self.chineseSize = bounded(chineseSize, 12...28, fallback: 15)
        self.backgroundOpacity = bounded(backgroundOpacity, 0...1, fallback: 0.38)
        self.bottomInset = bounded(bottomInset, 8...160, fallback: 24)
    }
    public var normalized: Self { Self(englishSize: englishSize, chineseSize: chineseSize, backgroundOpacity: backgroundOpacity, bottomInset: bottomInset) }
    enum CodingKeys: String, CodingKey { case englishSize, chineseSize, backgroundOpacity, bottomInset }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(englishSize: (try? c.decode(Double.self, forKey: .englishSize)) ?? 23,
                  chineseSize: (try? c.decode(Double.self, forKey: .chineseSize)) ?? 15,
                  backgroundOpacity: (try? c.decode(Double.self, forKey: .backgroundOpacity)) ?? 0.38,
                  bottomInset: (try? c.decode(Double.self, forKey: .bottomInset)) ?? 24)
    }
}

public struct PlayerWindowSize: Codable, Equatable {
    public let width: Double
    public let height: Double
    public init(width: Double = 1260, height: Double = 800) {
        self.width = bounded(width, 240...7680, fallback: 1260)
        self.height = bounded(height, 240...4320, fallback: 800)
    }
    enum CodingKeys: String, CodingKey { case width, height }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: (try? c.decode(Double.self, forKey: .width)) ?? 1260,
                  height: (try? c.decode(Double.self, forKey: .height)) ?? 800)
    }
}

public struct ViewingPreferences: Codable, Equatable {
    public var volume: Double = 80
    public var speed: Double = 1
    public var windowSize = PlayerWindowSize()
    public var subtitles = SubtitleAppearance()
    public var linkedSubtitleOffsets = false
    public var fitVideoWindow = false
    public var screenshot = ScreenshotPreferences()
    public init() {}
    public mutating func normalize() {
        volume = bounded(volume, 0...100, fallback: 80)
        speed = bounded(speed, 0.5...2, fallback: 1)
        subtitles = subtitles.normalized
        screenshot = screenshot.normalized
    }
    enum CodingKeys: String, CodingKey { case volume, speed, windowSize, subtitles, linkedSubtitleOffsets, fitVideoWindow, screenshot }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = (try? c.decode(Double.self, forKey: .volume)) ?? 80
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? 1
        windowSize = (try? c.decode(PlayerWindowSize.self, forKey: .windowSize)) ?? PlayerWindowSize()
        subtitles = (try? c.decode(SubtitleAppearance.self, forKey: .subtitles)) ?? SubtitleAppearance()
        linkedSubtitleOffsets = (try? c.decode(Bool.self, forKey: .linkedSubtitleOffsets)) ?? false
        fitVideoWindow = (try? c.decode(Bool.self, forKey: .fitVideoWindow)) ?? false
        screenshot = (try? c.decode(ScreenshotPreferences.self, forKey: .screenshot)) ?? ScreenshotPreferences()
        normalize()
    }
}
