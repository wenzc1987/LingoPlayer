import Foundation

public enum SubtitleDisplayMode: String, Codable, CaseIterable, Sendable {
    case bilingual, english, hidden
    public var title: String {
        switch self { case .bilingual: return "双语"; case .english: return "英文"; case .hidden: return "无字幕" }
    }
    public var next: Self { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
}

public struct TranscriptRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let english: SubtitleCue?
    public let chinese: [SubtitleCue]
    public let start: Double
    public let end: Double
    public let chineseText: String
    public let searchText: String
    public var playbackStart: Double { max(0, start) }
    fileprivate init(english: SubtitleCue?, chinese: [SubtitleCue], start: Double, end: Double) {
        self.english = english; self.chinese = chinese; self.start = start; self.end = end
        id = english.map { "en:\($0.id)" } ?? "zh:\(chinese.first!.id)"
        chineseText = chinese.map(\.text).joined(separator: "\n")
        searchText = ((english?.text ?? "") + "\n" + chineseText).lowercased()
    }
}

/// Immutable, reusable timeline index. Neither matching nor searching is rebuilt on playback ticks.
public struct TranscriptDocument: Sendable {
    public let rows: [TranscriptRow]
    private let prefixEnd: [Double]
    public init(english: [SubtitleCue] = [], chinese: [SubtitleCue] = [], englishOffset: Double = 0, chineseOffset: Double = 0) {
        let zh = chinese.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        let zhStarts = zh.map { $0.start + chineseOffset }
        var zhEnds: [Double] = [], maximum = -Double.infinity
        for cue in zh { maximum = max(maximum, cue.end + chineseOffset); zhEnds.append(maximum) }
        var used = Set<String>(), result: [TranscriptRow] = []
        for cue in english {
            let start = cue.start + englishOffset, end = cue.end + englishOffset
            var index = Self.lowerBound(zhStarts, end) - 1
            var matches: [SubtitleCue] = []
            while index >= 0 && zhEnds[index] > start {
                let candidate = zh[index]
                if candidate.end + chineseOffset > start { matches.append(candidate); used.insert(candidate.id) }
                index -= 1
            }
            result.append(.init(english: cue, chinese: matches.reversed(), start: start, end: end))
        }
        for cue in zh where !used.contains(cue.id) {
            result.append(.init(english: nil, chinese: [cue], start: cue.start + chineseOffset, end: cue.end + chineseOffset))
        }
        rows = result.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if ($0.english != nil) != ($1.english != nil) { return $0.english != nil }
            return $0.id < $1.id
        }
        maximum = -Double.infinity
        prefixEnd = rows.map { maximum = max(maximum, $0.end); return maximum }
    }
    private static func lowerBound(_ starts: [Double], _ time: Double) -> Int {
        var low = 0, high = starts.count
        while low < high { let mid = (low + high) / 2; if starts[mid] < time { low = mid + 1 } else { high = mid } }
        return low
    }
    private func startedCount(at time: Double) -> Int {
        var low = 0, high = rows.count
        while low < high { let mid = (low + high) / 2; if rows[mid].start <= time { low = mid + 1 } else { high = mid } }
        return low
    }
    public func activeIDs(at time: Double) -> Set<String> {
        var index = startedCount(at: time) - 1, result = Set<String>()
        while index >= 0 && prefixEnd[index] > time {
            if rows[index].end > time { result.insert(rows[index].id) }
            index -= 1
        }
        return result
    }
    public func anchorID(at time: Double) -> String? {
        let count = startedCount(at: time)
        return rows.isEmpty ? nil : rows[max(0, count - 1)].id
    }
    public func search(_ query: String) -> [TranscriptRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return needle.isEmpty ? rows : rows.filter { $0.searchText.contains(needle) }
    }
}

public struct SentenceLoop: Equatable, Sendable {
    public static let defaultTailPadding = 0.8
    public static func clampedTailPadding(_ value: Double) -> Double {
        value.isFinite ? min(3, max(0, value)) : defaultTailPadding
    }
    public let cueID: String
    public let start: Double
    public let end: Double
    public init?(cue: SubtitleCue, offset: Double, duration: Double, tailPadding: Double = 0) {
        let shiftedStart = cue.start + offset, shiftedEnd = cue.end + offset
        let start = max(0, shiftedStart)
        guard shiftedStart.isFinite, shiftedEnd.isFinite, duration.isFinite, duration > 0,
              shiftedEnd > shiftedStart, min(duration, shiftedEnd) > start else { return nil }
        cueID = cue.id; self.start = start
        // Display boundaries need not contain the entire spoken phrase. Padding
        // belongs to listening controls and must never change the subtitle offset.
        end = min(duration, shiftedEnd + Self.clampedTailPadding(tailPadding))
    }
    public func reachedEnd(at position: Double, eof: Bool) -> Bool {
        eof || position >= end
    }
}
