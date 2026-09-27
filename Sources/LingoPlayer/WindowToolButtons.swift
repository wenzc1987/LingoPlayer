import SwiftUI

struct WindowToolButtons: View {
    @ObservedObject var model: AppModel
    @ObservedObject var viewing: ViewingPreferencesStore
    @ObservedObject var window: PlayerWindowPresentation
    @ObservedObject var screenshots: ScreenshotController
    init(model: AppModel) {
        self.model = model; viewing = model.viewing; window = model.windowPresentation; screenshots = model.screenshots
    }
    var body: some View {
        Toggle(isOn: Binding(get: { viewing.fitVideoWindow }, set: { viewing.setFitVideoWindow($0) })) {
            symbol("aspectratio", active: viewing.fitVideoWindow)
        }.toggleStyle(.button).buttonStyle(.plain)
            .accessibilityLabel("无黑边").accessibilityValue(viewing.fitVideoWindow ? "已开启" : "已关闭")
            .accessibilityIdentifier("fit-video-window").help(fitHelp)
        Button { model.onToggleFullScreen?() } label: {
            symbol(window.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", active: window.isFullScreen)
        }.disabled(window.isTransitioning).help(window.fullScreenHelp)
            .accessibilityLabel(window.fullScreenHelp).accessibilityValue(window.isFullScreen ? "全屏" : "窗口")
            .accessibilityIdentifier("toggle-fullscreen")
        Button { screenshots.capture(model: model) } label: {
            if screenshots.isCapturing { ProgressView().controlSize(.small).frame(width: 28, height: 32) }
            else { symbol("camera") }
        }.disabled(!model.playbackReady || model.videoAspect == nil || screenshots.isCapturing || window.isTransitioning)
            .help(screenshotHelp).accessibilityLabel(screenshotHelp).accessibilityIdentifier("capture-screenshot")
    }
    private var fitHelp: String {
        if viewing.fitVideoWindow {
            return window.isFullScreen ? "无黑边已开启，退出全屏后生效；点击关闭" : "无黑边已开启；点击恢复自由窗口比例"
        }
        return "开启无黑边：窗口随视频比例缩放，完整显示画面"
    }
    private var screenshotHelp: String {
        if screenshots.isCapturing { return "正在保存截图…" }
        if !model.playbackReady || model.videoAspect == nil { return "截图：请先打开视频" }
        let preferences = viewing.screenshot
        let destination = preferences.clipboard && preferences.file ? "剪贴板和文件" : preferences.file ? "文件" : "剪贴板"
        return "截图：保存视频画面和当前字幕到\(destination)"
    }
    private func symbol(_ name: String, active: Bool = false) -> some View {
        Image(systemName: name).font(.system(size: 16))
            .foregroundStyle(active ? Palette.accent : .white.opacity(0.9))
            .frame(width: 28, height: 32)
            .background(active ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
