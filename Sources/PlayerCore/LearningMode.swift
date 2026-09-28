import Foundation
import NaturalLanguage

public enum LearningActivationPolicy: String, Codable, CaseIterable, Sendable {
    case automatic, manual
    public var title: String { self == .automatic ? "英文识别成功后自动开启" : "手动开启学习模式" }
}

public struct SubtitleLanguageAssessment: Sendable {
    public let language: String?
    public let confidence: Double
    public let letterCount: Int
    public var isEnglish: Bool { language == "en" && letterCount >= 30 && confidence >= 0.85 }
    public static func speechText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\[[^\\]]*\\]|【[^】]*】|\\([^)]*\\)", with: " ", options: .regularExpression)
    }

    public static func assess(_ cues: [SubtitleCue]) -> Self {
        // Uniform sampling prevents an opening title or a single borrowed word
        // from deciding the language of an entire film. Never constrain to English.
        let step = max(1, cues.count / 64)
        let sample = stride(from: 0, to: cues.count, by: step).prefix(64).map { speechText(cues[$0].text) }.joined(separator: "\n")
        let text = String(sample.prefix(8192))
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 30 else { return Self(language: nil, confidence: 0, letterCount: letters) }
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        let result = recognizer.languageHypotheses(withMaximum: 3).max { $0.value < $1.value }
        return Self(language: result?.key.rawValue, confidence: result?.value ?? 0, letterCount: letters)
    }
}

public enum LearningModeRules {
    public static func eligible(ready: Bool, duration: Double, english: [SubtitleCue], offset: Double) -> Bool {
        ready && duration.isFinite && duration > 0 && offset.isFinite && english.contains {
            $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.end + offset > 0 && $0.start + offset < duration
        }
    }
    public static func enabled(eligible: Bool, policy: LearningActivationPolicy, override: Bool?) -> Bool {
        eligible && (override ?? (policy == .automatic))
    }
}
