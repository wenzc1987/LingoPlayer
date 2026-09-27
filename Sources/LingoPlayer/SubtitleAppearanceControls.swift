import SwiftUI
import PlayerCore

struct SubtitleAppearanceControls: View {
    @ObservedObject var viewing: ViewingPreferencesStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("实时预览").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") { viewing.setSubtitles(SubtitleAppearance()) }
                    .accessibilityIdentifier("reset-subtitle-appearance")
            }
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(white: 0.3), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 6) {
                    Text("Listen and learn.").font(.system(size: viewing.subtitles.englishSize, weight: .medium))
                    Text("听一句，学一句。").font(.system(size: viewing.subtitles.chineseSize))
                }
                .foregroundStyle(.white).multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.black.opacity(viewing.subtitles.backgroundOpacity), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 8).padding(.bottom, min(50, viewing.subtitles.bottomInset / 3))
            }.frame(height: 156).clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("subtitle-appearance-preview")
            adjustment("英文字号", key: \.englishSize, range: 16...36, step: 1, suffix: "pt", id: "subtitle-english-size")
            adjustment("中文字幕字号", key: \.chineseSize, range: 12...28, step: 1, suffix: "pt", id: "subtitle-chinese-size")
            adjustment("背景不透明度", key: \.backgroundOpacity, range: 0...1, step: 0.01, suffix: "%", id: "subtitle-background")
            adjustment("距底部", key: \.bottomInset, range: 8...160, step: 1, suffix: "pt", id: "subtitle-position")
            Text("画面同步更新，后续视频沿用此设置。字幕较长时会自动限制上移距离，为操作面板留出空间。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 2)
    }
    private func adjustment(_ title: String, key: WritableKeyPath<SubtitleAppearance, Double>, range: ClosedRange<Double>, step: Double, suffix: String, id: String) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((viewing.subtitles[keyPath: key] * (suffix == "%" ? 100 : 1)).rounded())) \(suffix)").monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 12))
            Slider(value: Binding(get: { viewing.subtitles[keyPath: key] }, set: { value in
                var appearance = viewing.subtitles; appearance[keyPath: key] = value; viewing.setSubtitles(appearance)
            }), in: range, step: step).accessibilityLabel(title).accessibilityIdentifier(id)
        }
    }
}
