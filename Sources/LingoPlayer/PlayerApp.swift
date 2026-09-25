import AppKit
import SwiftUI

@main
struct LingoPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var learningWindow: NSWindow?
    private var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        let model = AppModel(); self.model = model
        model.onDetach = { [weak self] in self?.detachLearning() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "LingoPlayer"; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 980, height: 640)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PlayerRootView(model: model).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        installMenu()
        if let index = CommandLine.arguments.firstIndex(of: "--self-test"), CommandLine.arguments.count > index + 2 {
            let video = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await SmokeCheck.run(model: model, window: window, video: video, output: output, detach: { self?.detachLearning() }, closeDetached: { self?.learningWindow?.performClose(nil) })
            }
            return
        }
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }), FileManager.default.fileExists(atPath: path) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.open(URL(fileURLWithPath: path)) }
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let path = filenames.first { model?.acceptDrop(URL(fileURLWithPath: path)) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    private func detachLearning() {
        guard let model else { return }
        if let learningWindow { learningWindow.makeKeyAndOrderFront(nil); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "学习 · LingoPlayer"; panel.minSize = NSSize(width: 340, height: 420)
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.contentView = NSHostingView(rootView: LearningPanel(model: model, detached: true).preferredColorScheme(.dark))
        if let screen = NSScreen.screens.first(where: { $0 != window?.screen }) {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 200, y: screen.visibleFrame.midY - 350))
        } else { panel.center() }
        learningWindow = panel; model.isDetached = true; panel.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === learningWindow { learningWindow = nil; model?.isDetached = false }
    }
    @objc private func openVideo() { model?.chooseVideo() }
    @objc private func openSubtitles() { model?.chooseSubtitle() }
    @objc private func settings() { model?.showSettings = true }
    @objc private func togglePlay() { model?.togglePlayback() }
    @objc private func resumeLearning() { model?.resumeLearning() }
    @objc private func replay() { model?.replaySentence() }
    private func installMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 LingoPlayer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ","); settingsItem.target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "退出 LingoPlayer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; menu.addItem(app)
        let file = NSMenuItem(title: "文件", action: nil, keyEquivalent: ""); let fileMenu = NSMenu(title: "文件")
        let open = fileMenu.addItem(withTitle: "打开视频…", action: #selector(openVideo), keyEquivalent: "o"); open.target = self
        let subs = fileMenu.addItem(withTitle: "导入字幕…", action: #selector(openSubtitles), keyEquivalent: "i"); subs.target = self
        file.submenu = fileMenu; menu.addItem(file)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); let editMenu = NSMenu(title: "编辑")
        for (name, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { editMenu.addItem(withTitle: name, action: action, keyEquivalent: key) }
        edit.submenu = editMenu; menu.addItem(edit)
        let playback = NSMenuItem(title: "播放", action: nil, keyEquivalent: ""); let playbackMenu = NSMenu(title: "播放")
        for (name, action, key) in [("播放 / 暂停", #selector(togglePlay), "p"), ("继续学习", #selector(resumeLearning), "return"), ("回放本句", #selector(replay), "r")] {
            let item = playbackMenu.addItem(withTitle: name, action: action, keyEquivalent: key == "return" ? "\r" : key); item.target = self
        }
        playback.submenu = playbackMenu; menu.addItem(playback)
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: ""); let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApplication.shared.mainMenu = menu; NSApplication.shared.windowsMenu = windowMenu
    }
}
