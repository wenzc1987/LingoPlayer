import SwiftUI
import PlayerCore

/// Immutable caption state, shared by the interactive overlay and screenshots.
struct SubtitleFrame {
    let english: [SubtitleCue]
    let chinese: String
    let hasContent: Bool
    let wordID: String?
    let lockedWordID: String?
    let appearance: SubtitleAppearance
    let display: SubtitleDisplayMode
    @MainActor init(model: AppModel) {
        english = model.activeEnglish; chinese = model.bilingualText
        hasContent = !model.activeEnglish.isEmpty || !model.activeChinese.isEmpty
        wordID = model.currentWordID; lockedWordID = model.subtitles.lockedWordID
        appearance = model.viewing.subtitles; display = model.preferences.subtitleDisplay
    }
}

struct SubtitleCaptionContent: View {
    let frame: SubtitleFrame
    var select: ((SubtitleCue, WordToken) -> Void)?
    var body: some View {
        VStack(spacing: 8) {
            if frame.hasContent {
                ForEach(frame.english) { cue in
                    WordWrap(spacing: 1, lineSpacing: 4) {
                        ForEach(cue.tokens) { token in
                            if token.isWord {
                                if let select {
                                    Button { select(cue, token) } label: { word(cue, token) }
                                        .buttonStyle(.plain).help("暂停并学习 \(token.text)")
                                        .accessibilityIdentifier("subtitle-word-\(cue.id)-\(token.id)")
                                } else { word(cue, token) }
                            } else {
                                Text(token.text.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: max(14, frame.appearance.englishSize - 2)))
                                    .foregroundStyle(.white.opacity(0.8)).padding(.vertical, 3)
                            }
                        }
                    }
                }
                if !frame.chinese.isEmpty {
                    Text(frame.chinese).font(.system(size: frame.appearance.chineseSize))
                        .foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                        .opacity(frame.display == .bilingual ? 1 : 0).accessibilityHidden(frame.display != .bilingual)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background { if frame.hasContent { RoundedRectangle(cornerRadius: 10).fill(.black.opacity(frame.appearance.backgroundOpacity)) } }
    }
    private func word(_ cue: SubtitleCue, _ token: WordToken) -> some View {
        let spoken = frame.wordID == "\(cue.id):\(token.id)"
        let locked = frame.lockedWordID == "\(cue.id):\(token.id)"
        return Text(token.text).font(.system(size: frame.appearance.englishSize, weight: spoken ? .semibold : .medium))
            .foregroundStyle(spoken ? .black : .white.opacity(0.93))
            .padding(.horizontal, 3).padding(.vertical, 3)
            .background(spoken ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay { if locked { RoundedRectangle(cornerRadius: 5).stroke(Palette.accent.opacity(0.75), lineWidth: 1) } }
            .contentShape(Rectangle())
    }
}
