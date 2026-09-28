import Foundation

public struct ParsedSubtitles: Sendable {
    public var cues: [SubtitleCue]
    public var primaryCues: [SubtitleCue]
    public var latinCandidates: [SubtitleCue]
    public var assessment: SubtitleLanguageAssessment
    public var english: [SubtitleCue]
    public var chinese: [SubtitleCue]
}

public enum SubtitleError: LocalizedError {
    case encoding, empty
    public var errorDescription: String? {
        switch self { case .encoding: return "无法读取字幕编码，请转换为 UTF-8。"; case .empty: return "没有找到有效的文字字幕。支持 SRT、ASS/SSA 和 WebVTT。" }
    }
}

public enum SubtitleParser {
    public static func parse(url: URL) throws -> ParsedSubtitles {
        try parse(data: Data(contentsOf: url), ext: url.pathExtension)
    }
    public static func parse(data: Data, ext: String) throws -> ParsedSubtitles {
        let encodings: [String.Encoding] = [.utf8, .utf16, String.Encoding(rawValue: 0x80000632), String.Encoding(rawValue: 0x80000A03), .windowsCP1252]
        guard let raw = encodings.lazy.compactMap({ String(data: data, encoding: $0) }).first else { throw SubtitleError.encoding }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{feff}", with: "")
        let cues = ["ass", "ssa"].contains(ext.lowercased()) ? parseASS(text) : parseSRT(text)
        guard !cues.isEmpty else { throw SubtitleError.empty }
        var english: [SubtitleCue] = [], chinese: [SubtitleCue] = [], primary: [SubtitleCue] = []
        for cue in cues {
            var en: [String] = [], zh: [String] = [], other: [String] = []
            for line in cue.text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !line.isEmpty {
                // Bilingual files conventionally separate languages by line. Mixed lines
                // preserve their Chinese text; only Latin runs become learning tokens.
                if line.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) || (0xf900...0xfaff).contains($0.value) }) { zh.append(line) }
                else {
                    other.append(line)
                    if line.range(of: "[A-Za-z]", options: .regularExpression) != nil { en.append(line) }
                }
            }
            if !en.isEmpty { english.append(SubtitleCue(id: cue.id + "-en", start: cue.start, end: cue.end, text: en.joined(separator: "\n"))) }
            if !zh.isEmpty { chinese.append(SubtitleCue(id: cue.id + "-zh", start: cue.start, end: cue.end, text: zh.joined(separator: "\n"))) }
            if !other.isEmpty { primary.append(SubtitleCue(id: cue.id, start: cue.start, end: cue.end, text: other.joined(separator: "\n"))) }
        }
        let candidates = english.sorted { $0.start < $1.start }
        let assessment = SubtitleLanguageAssessment.assess(candidates)
        return ParsedSubtitles(cues: cues.sorted { $0.start < $1.start }, primaryCues: (assessment.isEnglish ? primary : cues).sorted { $0.start < $1.start }, latinCandidates: candidates, assessment: assessment,
                               english: assessment.isEnglish ? candidates.filter { SubtitleLanguageAssessment.speechText($0.text).unicodeScalars.contains(where: CharacterSet.letters.contains) } : [], chinese: chinese.sorted { $0.start < $1.start })
    }
    public static func timestamp(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 2 || parts.count == 3, let seconds = Double(parts.last!), let minutes = Double(parts[parts.count - 2]), seconds >= 0, seconds < 60, minutes >= 0, minutes < 60 else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let hours, hours.isFinite, hours >= 0 else { return nil }
        let result = hours * 3600 + minutes * 60 + seconds
        return result.isFinite ? result : nil
    }
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func parseSRT(_ text: String) -> [SubtitleCue] {
        let lines = text.components(separatedBy: "\n")
        var result: [SubtitleCue] = [], index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.contains("-->") else { index += 1; continue }
            let times = line.components(separatedBy: "-->")
            guard times.count == 2, let start = timestamp(times[0]), let endPart = times[1].split(whereSeparator: \.isWhitespace).first,
                  let end = timestamp(String(endPart)), end > start else { index += 1; continue }
            index += 1
            var body: [String] = []
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty && !lines[index].contains("-->") {
                body.append(lines[index]); index += 1
            }
            let value = clean(body.joined(separator: "\n"))
            if !value.isEmpty { result.append(SubtitleCue(id: "cue-\(result.count)", start: start, end: end, text: value)) }
        }
        return result
    }
    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var inEvents = false
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var result: [SubtitleCue] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") { fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }; continue }
            guard line.lowercased().hasPrefix("dialogue:"), let startIndex = fields.firstIndex(of: "start"), let endIndex = fields.firstIndex(of: "end"), let textIndex = fields.firstIndex(of: "text"), textIndex == fields.count - 1 else { continue }
            let values = line.dropFirst(9).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false).map(String.init)
            guard values.count == fields.count, let start = timestamp(values[startIndex]), let end = timestamp(values[endIndex]), end > start else { continue }
            // ASS vector drawings are graphics, not words.
            guard values[textIndex].range(of: "\\\\p[1-9]", options: .regularExpression) == nil else { continue }
            let value = clean(values[textIndex])
            if !value.isEmpty { result.append(SubtitleCue(id: "cue-\(result.count)", start: start, end: end, text: value)) }
        }
        return result
    }
}
