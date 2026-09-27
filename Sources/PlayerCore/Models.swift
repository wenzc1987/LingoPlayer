import Foundation
import CryptoKit

public enum SubtitleLanguage: String, Codable, CaseIterable, Sendable {
    case english, chinese
    public var title: String { self == .english ? "英文" : "中文" }
}

public struct SubtitleCue: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var text: String { didSet { cachedTokens = WordToken.tokenize(text) } }
    private var cachedTokens: [WordToken]
    enum CodingKeys: String, CodingKey { case id, start, end, text }
    public init(id: String, start: Double, end: Double, text: String) {
        self.id = id; self.start = start; self.end = end; self.text = text; cachedTokens = WordToken.tokenize(text)
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), start: try values.decode(Double.self, forKey: .start),
                  end: try values.decode(Double.self, forKey: .end), text: try values.decode(String.self, forKey: .text))
    }
    public var tokens: [WordToken] { cachedTokens }
    public func contains(_ time: Double, offset: Double = 0) -> Bool {
        time >= start + offset && time < end + offset
    }
}

public struct WordToken: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var text: String
    public var isWord: Bool
    public init(id: Int, text: String, isWord: Bool) {
        self.id = id; self.text = text; self.isWord = isWord
    }
    public var normalized: String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
    }
    public static func tokenize(_ text: String) -> [WordToken] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).enumerated().map { index, match in
            let value = ns.substring(with: match.range)
            return WordToken(id: index, text: value, isWord: value.first?.isASCII == true && value.first?.isLetter == true)
        }
    }
    private static let regex = try! NSRegularExpression(pattern: "[A-Za-z]+(?:['’\\-][A-Za-z]+)*|[^A-Za-z]+")
}

public struct TimedWord: Codable, Equatable, Sendable {
    public var cueID: String
    public var tokenIndex: Int
    public var start: Double
    public var end: Double
    public init(cueID: String, tokenIndex: Int, start: Double, end: Double) {
        self.cueID = cueID; self.tokenIndex = tokenIndex; self.start = start; self.end = end
    }
}

public struct LearningSelection: Equatable, Sendable {
    public var cue: SubtitleCue
    public var token: WordToken
    public var chinese: String
    public var playbackStart: Double
    public var playbackEnd: Double
    public init(cue: SubtitleCue, token: WordToken, chinese: String, offset: Double) {
        self.cue = cue; self.token = token; self.chinese = chinese
        playbackStart = max(0, cue.start + offset); playbackEnd = max(0, cue.end + offset)
    }
}

/// The spoken word is transient; the reader's selection remains stable while locked.
public struct LearningState: Sendable, Equatable {
    public private(set) var spoken: LearningSelection?
    public private(set) var locked: LearningSelection?
    public var selected: LearningSelection? { locked ?? spoken }
    public var isLocked: Bool { locked != nil }
    public init() {}
    public mutating func follow(_ selection: LearningSelection?) { spoken = selection }
    public mutating func lock(_ selection: LearningSelection) { locked = selection }
    public mutating func resumeFollowing() { locked = nil }
    public mutating func reset() { spoken = nil; locked = nil }
}

public struct DictionaryEntry: Codable, Equatable, Sendable {
    public var word: String
    public var phonetic: String
    public var definition: String
    public var translation: String
    public var exchange: String
    public init(word: String, phonetic: String = "", definition: String = "", translation: String = "", exchange: String = "") {
        self.word = word; self.phonetic = phonetic; self.definition = definition
        self.translation = translation; self.exchange = exchange
    }
    public var lemma: String? {
        exchange.split(separator: "/").first(where: { $0.hasPrefix("0:") }).map { String($0.dropFirst(2)) }
    }
}

public struct MediaIdentity: Codable, Equatable, Sendable {
    public var key: String
    public var path: String
    public var title: String
    public var bytes: UInt64
    public init(url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        path = url.standardizedFileURL.path
        title = url.deletingPathExtension().lastPathComponent
        bytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        key = Digest.string("\(path)|\(bytes)|\(modified)")
    }
}

public enum Digest {
    public static func data(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func string(_ text: String) -> String { data(Data(text.utf8)) }
}

public struct SavedPlayback: Codable, Sendable {
    public var position: Double = 0
    public var englishPath: String?
    public var chinesePath: String?
    public var englishOffset: Double = 0
    public var chineseOffset: Double = 0
    public var sentenceTailPadding: Double = SentenceLoop.defaultTailPadding
    public var audioStream: Int?
    public init() {}
    enum CodingKeys: String, CodingKey { case position, englishPath, chinesePath, englishOffset, chineseOffset, sentenceTailPadding, audioStream }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        position = try values.decodeIfPresent(Double.self, forKey: .position) ?? 0
        englishPath = try values.decodeIfPresent(String.self, forKey: .englishPath)
        chinesePath = try values.decodeIfPresent(String.self, forKey: .chinesePath)
        englishOffset = try values.decodeIfPresent(Double.self, forKey: .englishOffset) ?? 0
        chineseOffset = try values.decodeIfPresent(Double.self, forKey: .chineseOffset) ?? 0
        sentenceTailPadding = SentenceLoop.clampedTailPadding(try values.decodeIfPresent(Double.self, forKey: .sentenceTailPadding) ?? SentenceLoop.defaultTailPadding)
        audioStream = try values.decodeIfPresent(Int.self, forKey: .audioStream)
    }
}

public enum Timeline {
    public static func active(_ cues: [SubtitleCue], at time: Double, offset: Double = 0) -> [SubtitleCue] {
        // Binary search bounds the scan to started cues; overlapping dialogue remains visible.
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start + offset <= time { low = middle + 1 } else { high = middle }
        }
        return cues[..<low].filter { $0.contains(time, offset: offset) }
    }
    public static func spoken(_ words: [TimedWord], at time: Double) -> TimedWord? {
        words.first { time >= $0.start && time < $0.end }
    }
    public static func nextBatch(_ cues: [SubtitleCue], completed: Set<String>, position: Double, offset: Double, horizon: Double = 30) -> [SubtitleCue] {
        let remaining = cues.filter { !completed.contains($0.id) && $0.end + offset > 0 && !$0.tokens.filter(\.isWord).isEmpty }
        guard let first = remaining.first(where: { $0.end + offset >= position }) ?? remaining.first else { return [] }
        return remaining.filter { $0.start >= first.start && $0.start < first.start + horizon }.prefix(30).map { $0 }
    }
}
