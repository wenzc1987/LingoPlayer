import AppKit
import SwiftUI
import PlayerCore

@main
struct LingoPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow?
    private var learningWindow: NSWindow?
    private var model: AppModel?
    private var keyboard: KeyboardRouter?
    private var terminationPrepared = false
    private var terminationInProgress = false
    private var pendingFiles: [URL] = []
    private var mainWindowTransition = false
    private var applyingWindowGeometry = false
    private var restoredVideoWindowSize: NSSize?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { NSApp.applicationIconImage = NSImage(contentsOf: icon) }
        let model = AppModel(); self.model = model
        model.onDetach = { [weak self] in self?.detachLearning() }
        model.onReattach = { [weak self] in self?.learningWindow?.performClose(nil) }
        model.onShortcutsChanged = { [weak self] in self?.installMenu() }
        let remembered = model.viewing.windowSize
        if model.viewing.fitVideoWindow { restoredVideoWindowSize = NSSize(width: remembered.width, height: remembered.height) }
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1260, height: 828)
        let size = NSSize(width: min(max(980, remembered.width), available.width), height: min(max(640, remembered.height), available.height - 28))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "LingoPlayer"; window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden; window.isOpaque = false; window.backgroundColor = .clear
        window.minSize = NSSize(width: 980, height: 640)
        window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: PlayerRootView(model: model).preferredColorScheme(.dark))
        // The delegate owns window limits, including the smaller cinema and
        // portrait sizes. SwiftUI's inferred minimum would overwrite them.
        content.sizingOptions = []
        window.contentView = content
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        window.delegate = self
        model.onWindowGeometryChanged = { [weak self] in self?.applyWindowGeometry() }
        model.viewing.onWindowModeChanged = { [weak self] in self?.applyWindowGeometry() }
        model.chrome.onVisibilityChange = { [weak window] visible in
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(button)?.isHidden = !visible
            }
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let keyboard = KeyboardRouter(model: model)
        keyboard.isPlayerWindow = { [weak self] candidate in
            guard let self, let candidate else { return false }
            return candidate === self.window || candidate === self.learningWindow
        }
        self.keyboard = keyboard; keyboard.install()
        installMenu()
        if let index = CommandLine.arguments.firstIndex(where: { ["--window-geometry-test", "--window-geometry-restore"].contains($0) }), CommandLine.arguments.count > index + 2 {
            Task { await WindowGeometrySmoke.run(model: model, window: window, folder: URL(fileURLWithPath: CommandLine.arguments[index + 1]), output: URL(fileURLWithPath: CommandLine.arguments[index + 2]), restore: CommandLine.arguments[index] == "--window-geometry-restore") }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--ui-performance-test"), CommandLine.arguments.count > index + 2 {
            Task { await UIResponsivenessSmoke.run(model: model, window: window, video: URL(fileURLWithPath: CommandLine.arguments[index + 1]), output: URL(fileURLWithPath: CommandLine.arguments[index + 2])) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(where: { ["--viewing-test", "--viewing-restore"].contains($0) }), CommandLine.arguments.count > index + 2 {
            Task { await ViewingSmoke.run(model: model, window: window, video: URL(fileURLWithPath: CommandLine.arguments[index + 1]), output: URL(fileURLWithPath: CommandLine.arguments[index + 2]), restore: CommandLine.arguments[index] == "--viewing-restore") }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--performance-test"), CommandLine.arguments.count > index + 2 {
            Task { await PerformanceSmoke.run(model: model, window: window, video: URL(fileURLWithPath: CommandLine.arguments[index + 1]), output: URL(fileURLWithPath: CommandLine.arguments[index + 2])) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--chrome-test"), CommandLine.arguments.count > index + 2 {
            Task { await ChromeSmoke.run(model: model, window: window, video: URL(fileURLWithPath: CommandLine.arguments[index + 1]), output: URL(fileURLWithPath: CommandLine.arguments[index + 2])) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--keyboard-test"), CommandLine.arguments.count > index + 2 {
            Task { [weak self] in
                await KeyboardSmoke.run(model: model, window: window, keyboard: keyboard,
                    video: URL(fileURLWithPath: CommandLine.arguments[index + 1]), output: URL(fileURLWithPath: CommandLine.arguments[index + 2]),
                    detach: { self?.detachLearning() }, learningWindow: { self?.learningWindow }, closeDetached: { self?.learningWindow?.performClose(nil) })
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(where: { ["--display-test", "--display-restore"].contains($0) }), CommandLine.arguments.count > index + 2 {
            Task { [weak self] in
                await DisplaySmoke.run(model: model, window: window, folder: URL(fileURLWithPath: CommandLine.arguments[index + 1]), output: URL(fileURLWithPath: CommandLine.arguments[index + 2]), restore: CommandLine.arguments[index] == "--display-restore", detach: { self?.detachLearning() }, closeDetached: { self?.learningWindow?.performClose(nil) })
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--alignment-repro"), CommandLine.arguments.count > index + 2 {
            Task { await AlignmentReproduction.run(model: model, request: URL(fileURLWithPath: CommandLine.arguments[index + 1]), output: URL(fileURLWithPath: CommandLine.arguments[index + 2])) }; return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--response-test"), CommandLine.arguments.count > index + 2 {
            Task { await ResponsivenessSmoke.run(model: model, window: window,
                request: URL(fileURLWithPath: CommandLine.arguments[index + 1]), output: URL(fileURLWithPath: CommandLine.arguments[index + 2])) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(where: { ["--practice-test", "--practice-restore"].contains($0) }), CommandLine.arguments.count > index + 2 {
            let restore = CommandLine.arguments[index] == "--practice-restore"
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await PracticeSmoke.run(model: model, window: window, keyboard: keyboard, folder: folder, output: output, restoreOnly: restore,
                    detach: { self?.detachLearning() }, learningWindow: { self?.learningWindow }, closeDetached: { self?.learningWindow?.performClose(nil) })
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(where: { ["--interaction-test", "--interaction-restore"].contains($0) }), CommandLine.arguments.count > index + 2 {
            let restore = CommandLine.arguments[index] == "--interaction-restore"
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await InteractionSmoke.run(model: model, window: window, keyboard: keyboard, folder: folder, output: output, restoreOnly: restore,
                    detach: { self?.detachLearning() }, learningWindow: { self?.learningWindow }, closeDetached: { self?.learningWindow?.performClose(nil) })
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--self-test"), CommandLine.arguments.count > index + 2 {
            let video = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await SmokeCheck.run(model: model, window: window, video: video, output: output, detach: { self?.detachLearning() }, closeDetached: { self?.learningWindow?.performClose(nil) })
            }
            return
        }
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        let files = pendingFiles + paths; pendingFiles = []
        if files.isEmpty { model.restoreQueue() } else { model.acceptFiles(files) }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let files = filenames.map { URL(fileURLWithPath: $0) }
        if let model { model.acceptFiles(files) } else { pendingFiles.append(contentsOf: files) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPrepared { return .terminateNow }
        if !terminationInProgress {
            terminationInProgress = true
            rememberMainWindowSize()
            Task {
                await model?.prepareShutdown(); terminationPrepared = true
                // Re-enter termination outside the active Swift concurrency job;
                // AppKit's nested terminateLater loop otherwise stalls that job.
                DispatchQueue.main.async { sender.terminate(nil) }
            }
        }
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { keyboard?.uninstall(); model?.shutdown() }
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
        learningWindow = panel; model.isDetached = true; model.sidebarTab = .queue; panel.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window { rememberMainWindowSize() }
        if let closing = notification.object as? NSWindow, closing === learningWindow { learningWindow = nil; model?.isDetached = false; model?.sidebarTab = .learning }
    }
    private func rememberMainWindowSize() {
        guard let window, !mainWindowTransition, !applyingWindowGeometry, !window.styleMask.contains(.fullScreen), !window.isZoomed,
              let size = window.contentView?.bounds.size, size.width > 0, size.height > 0 else { return }
        model?.viewing.setWindowSize(PlayerWindowSize(width: size.width, height: size.height))
    }
    private var videoWindowGeometry: VideoWindowGeometry? {
        guard let model, model.viewing.fitVideoWindow, let aspect = model.videoAspect else { return nil }
        return VideoWindowGeometry(aspect: aspect, sidebar: model.preferences.sidebarCollapsed ? 0 : 333)
    }
    private func availableContentSize(_ window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).size
    }
    private func applyWindowGeometry() {
        guard let window, !mainWindowTransition, !applyingWindowGeometry, !window.styleMask.contains(.fullScreen) else { return }
        // Keep the current shape while the next video's display size is loading.
        if model?.viewing.fitVideoWindow == true && model?.media != nil && model?.videoAspect == nil { return }
        applyingWindowGeometry = true
        defer { applyingWindowGeometry = false }
        let available = availableContentSize(window)
        let current = window.contentView?.bounds.size ?? window.frame.size
        let target: NSSize
        if let geometry = videoWindowGeometry {
            window.contentMinSize = geometry.minimum(in: available)
            target = geometry.fit(restoredVideoWindowSize ?? current, in: available)
            restoredVideoWindowSize = nil
        } else {
            if model?.viewing.fitVideoWindow == false { restoredVideoWindowSize = nil }
            let minimum = NSSize(width: min(980, available.width), height: min(640, available.height))
            window.contentMinSize = minimum
            target = NSSize(width: min(available.width, max(current.width, minimum.width)), height: min(available.height, max(current.height, minimum.height)))
        }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        }
        if abs(window.frame.width - frame.width) > 0.5 || abs(window.frame.height - frame.height) > 0.5 ||
            abs(window.frame.minX - frame.minX) > 0.5 || abs(window.frame.minY - frame.minY) > 0.5 {
            window.setFrame(frame, display: true)
        }
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === window, !mainWindowTransition, !applyingWindowGeometry,
              !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let available = availableContentSize(sender)
        guard let geometry = videoWindowGeometry else {
            let size = NSSize(width: min(available.width, max(980, proposed.width)), height: min(available.height, max(640, proposed.height)))
            return sender.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        }
        let current = sender.contentView?.bounds.size ?? sender.frame.size
        let usingHeight = abs(proposed.height - current.height) * geometry.aspect > abs(proposed.width - current.width)
        let size = geometry.fit(proposed, in: available, usingHeight: usingHeight)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
    }
    func windowDidResize(_ notification: Notification) {
        if let changed = notification.object as? NSWindow, changed === window, !changed.inLiveResize {
            if videoWindowGeometry != nil { applyWindowGeometry() }
            rememberMainWindowSize()
        }
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        if let changed = notification.object as? NSWindow, changed === window { applyWindowGeometry(); rememberMainWindowSize() }
    }
    func windowDidChangeScreen(_ notification: Notification) {
        if let changed = notification.object as? NSWindow, changed === window { applyWindowGeometry() }
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        if let changed = notification.object as? NSWindow, changed === window {
            rememberMainWindowSize(); mainWindowTransition = true
        }
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        if let changed = notification.object as? NSWindow, changed === window { mainWindowTransition = false }
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        if let changed = notification.object as? NSWindow, changed === window { mainWindowTransition = true }
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        if let changed = notification.object as? NSWindow, changed === window { mainWindowTransition = false; applyWindowGeometry() }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        if window === self.window { mainWindowTransition = false; applyWindowGeometry() }
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        if window === self.window { mainWindowTransition = false; applyWindowGeometry() }
    }
    @objc private func openVideo() { model?.chooseVideo() }
    @objc private func openSubtitles() { model?.chooseSubtitle() }
    @objc private func settings() { model?.showSettings = true }
    @objc private func dispatchAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = PlayerAction(rawValue: raw) else { return }
        model?.perform(action)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let raw = menuItem.representedObject as? String, let action = PlayerAction(rawValue: raw) else { return true }
        return keyboard?.blocked == false && model?.canPerform(action) == true
    }
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
        for action in PlayerAction.allCases {
            let binding = model?.preferences.shortcut(for: action)
            let item = playbackMenu.addItem(withTitle: action.title, action: #selector(dispatchAction(_:)), keyEquivalent: binding?.menuKey ?? "")
            item.keyEquivalentModifierMask = binding?.menuModifiers ?? []
            item.representedObject = action.rawValue; item.target = self
        }
        playback.submenu = playbackMenu; menu.addItem(playback)
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: ""); let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApplication.shared.mainMenu = menu; NSApplication.shared.windowsMenu = windowMenu
    }
}
