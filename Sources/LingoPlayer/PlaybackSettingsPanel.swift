import SwiftUI
import PlayerCore

struct PlaybackSettingsPanel: View {
    @ObservedObject var viewing: ViewingPreferencesStore
    var body: some View {
        Form {
            Toggle("拖动进度条显示缩略图", isOn: Binding(get: { viewing.seekPreviewEnabled }, set: { viewing.setSeekPreviewEnabled($0) }))
                .accessibilityIdentifier("seek-preview-enabled")
            Text("拖动时显示附近画面，松手后跳转。预览仅保存在本次播放的内存中。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("学习模式启动方式", selection: Binding(get: { viewing.learningActivation }, set: { viewing.setLearningActivation($0) })) {
                Text("自动").tag(LearningActivationPolicy.automatic)
                Text("手动").tag(LearningActivationPolicy.manual)
            }.accessibilityIdentifier("learning-activation-policy")
            Text("识别到有效英文字幕后，自动开启英语学习，或在字幕菜单手动开启。每部影片都可以随时退出学习，继续普通播放。")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
