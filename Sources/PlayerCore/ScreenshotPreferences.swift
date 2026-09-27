import Foundation

public struct ScreenshotPreferences: Codable, Equatable, Sendable {
    public var clipboard = true
    public var file = false
    public var directory = ""
    public init() {}
    public var hasDestination: Bool { clipboard || file }
    public var normalized: Self {
        var result = self
        if !result.hasDestination { result.clipboard = true }
        result.directory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
    enum CodingKeys: String, CodingKey { case clipboard, file, directory }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clipboard = (try? c.decode(Bool.self, forKey: .clipboard)) ?? true
        file = (try? c.decode(Bool.self, forKey: .file)) ?? false
        directory = (try? c.decode(String.self, forKey: .directory)) ?? ""
        self = normalized
    }
    public static func filename(title: String, position: Double, id: UUID = UUID()) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var safe = ""
        for scalar in title.unicodeScalars {
            let part = invalid.contains(scalar) ? "_" : String(scalar)
            guard safe.utf8.count + part.utf8.count <= 120 else { break }
            safe += part
        }
        let clean = safe.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let seconds = Int(min(999_999_999, max(0, position.isFinite ? position : 0)))
        return "\(clean.isEmpty ? "LingoPlayer" : clean)-\(String(format: "%02d-%02d-%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))-\(id.uuidString).png"
    }
}
