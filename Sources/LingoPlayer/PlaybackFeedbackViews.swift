import SwiftUI

struct VolumeSymbol: View {
    let volume: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: volume / 100)
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : Int(volume.rounded()))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: volume)
            .accessibilityHidden(true)
    }
}

struct PlaybackFeedbackOverlay: View {
    @ObservedObject var chrome: PlayerChrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if let feedback = chrome.feedback {
                VStack(spacing: 10) {
                    HStack(spacing: 14) {
                        Group {
                            if let volume = feedback.volume { VolumeSymbol(volume: volume) }
                            else { Image(systemName: feedback.symbol) }
                        }
                        .font(.system(size: 27, weight: .medium)).foregroundStyle(Palette.accent)
                        .frame(width: 42, height: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(feedback.title).font(.system(size: 23, weight: .semibold)).monospacedDigit()
                                .contentTransition(.numericText())
                            if let detail = feedback.detail {
                                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            }
                        }
                    }
                    if let volume = feedback.volume {
                        HStack(spacing: 3) {
                            ForEach(0..<20) { index in
                                Capsule().fill(Double(index) < volume / 5 ? Palette.accent : .white.opacity(0.16))
                                    .frame(width: 6, height: 4)
                            }
                        }
                    }
                }
                .foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 14)
                .frame(minWidth: 180, maxWidth: 340)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1) }
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                .accessibilityElement(children: .combine).accessibilityIdentifier("playback-feedback")
                .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.96)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: chrome.feedback)
    }
}
