import AppKit
import SwiftUI
import PlayerCore

struct ScreenshotSettingsPanel: View {
    @ObservedObject var model: AppModel
    @State private var draft: ScreenshotPreferences
    @State private var message = ""
    init(model: AppModel) {
        self.model = model
        var preferences = model.viewing.screenshot
        if preferences.directory.isEmpty { preferences.directory = ScreenshotController.defaultDirectory.path }
        _draft = State(initialValue: preferences)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("截图").font(.headline)
            Text("保存视频画面和当前显示的字幕，不包含操作面板、片名和侧栏。")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox("保存方式（可同时选择）") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("内存（系统剪贴板）", isOn: $draft.clipboard)
                        .toggleStyle(.checkbox).accessibilityIdentifier("screenshot-save-clipboard")
                        .help("复制图片到系统剪贴板，可直接粘贴；不生成截图文件")
                    Toggle("文件（PNG）", isOn: $draft.file)
                        .toggleStyle(.checkbox).accessibilityIdentifier("screenshot-save-file")
                        .help("将截图保存为 PNG 文件")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("截图保存路径").font(.callout)
                HStack {
                    TextField("文件夹路径", text: $draft.directory).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("screenshot-directory")
                    Button("选择文件夹…") {
                        model.filePanels.present { panel in
                            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                            panel.message = "选择截图保存文件夹"
                            panel.directoryURL = try? ScreenshotController.directory(for: draft)
                        } completion: { urls in if let url = urls.first { draft.directory = url.path } }
                    }.accessibilityIdentifier("choose-screenshot-directory").help("选择截图文件保存位置")
                }
                Text("勾选“文件”后生效；文件名包含片名和播放时间，每次截图单独保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !draft.hasDestination { Text("请至少选择一种保存方式。").foregroundStyle(.orange) }
            if !message.isEmpty { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            Spacer()
            HStack {
                Text("默认仅保存到剪贴板。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存") {
                    do {
                        if draft.file { _ = try ScreenshotController.directory(for: draft) }
                        model.viewing.setScreenshot(draft); model.showSettings = false
                    } catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(!draft.hasDestination)
                    .accessibilityIdentifier("save-screenshot-settings")
            }
        }.padding(18)
    }
}
