import AppKit
import PlayerCore

/// Uses an isolated pasteboard and data directory; never changes the user's clipboard.
@MainActor enum ToolbarSmoke {
    static func run(model: AppModel, window: NSWindow, keyboard: KeyboardRouter, video: URL, output: URL, restore: Bool) async {
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail]); print(name, passed, detail); fflush(stdout)
        }
        func delay(_ seconds: Double = 0.25) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline { if predicate() { return true }; await delay(0.025) }; return predicate()
        }
        func find(_ root: NSObject, _ id: String, depth: Int = 0) -> NSObject? {
            guard depth < 40 else { return nil }
            let key = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
            if root.responds(to: key), root.perform(key)?.takeUnretainedValue() as? String == id { return root }
            if root.responds(to: children), let items = root.perform(children)?.takeUnretainedValue() as? [NSObject] {
                for item in items { if let node = find(item, id, depth: depth + 1) { return node } }
            }; return nil
        }
        func node(_ id: String) -> NSObject? { NSApp.windows.filter(\.isVisible).compactMap { find($0, id) }.first }
        @discardableResult func press(_ id: String) async -> Bool {
            guard let node = node(id), node.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return false }
            _ = node.perform(NSSelectorFromString("accessibilityPerformPress")); await delay(); return true
        }
        func page(_ index: Int) async {
            if let segments = node("settings-page")?.value(forKey: "accessibilityChildren") as? [NSObject], segments.count > index {
                _ = segments[index].perform(NSSelectorFromString("accessibilityPerformPress"))
            }; await delay()
        }
        func value(_ id: String, _ key: String = "accessibilityValue") -> Any? { node(id)?.value(forKey: key) }
        func keyEvent(_ key: Shortcut, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.menuModifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: (NSApp.keyWindow ?? window).windowNumber,
                context: nil, characters: key.menuKey, charactersIgnoringModifiers: key.menuKey, isARepeat: repeatKey, keyCode: key.keyCode)!
        }
        func key(_ shortcut: Shortcut, repeatKey: Bool = false) async {
            NSApp.postEvent(keyEvent(shortcut, repeatKey: repeatKey), atStart: false); await delay(0.2)
        }
        let learningToolIDs = ["action-previousSentence", "action-nextSentence", "action-toggleSentenceLoop"]
        let allToolIDs = ["open-video", "action-previousSentence", "action-backward", "action-playPause", "action-forward", "action-nextSentence", "action-toggleSentenceLoop", "subtitle-menu", "speed-control", "volume-control", "open-queue", "toggle-sidebar", "fit-video-window", "toggle-fullscreen", "capture-screenshot", "quick-settings"]
        var toolIDs: [String] { allToolIDs.filter { model.isLearningMode || !learningToolIDs.contains($0) } }
        func singleRow() -> Bool {
            let frames = toolIDs.compactMap { (value($0, "accessibilityFrame") as? NSValue)?.rectValue }
            let stage = window.convertToScreen(model.videoView.convert(model.videoView.bounds, to: nil))
            // AppKit reports glyph bounds for some buttons and hit bounds for
            // others. A shared vertical band detects wrapping without assuming
            // every accessibility frame has the same optical center.
            let valid = (model.isLearningMode || learningToolIDs.allSatisfy { node($0) == nil }) &&
                frames.count == toolIDs.count && frames.allSatisfy({ !$0.isEmpty && stage.contains($0) }) &&
                (frames.map(\.minY).max() ?? 0) < (frames.map(\.maxY).min() ?? 0)
            if !valid { print("toolbar-layout", stage, Array(zip(toolIDs, frames))); fflush(stdout) }
            return valid
        }
        func resize(_ size: NSSize) async {
            var frame = window.frame; frame.size = window.delegate?.windowWillResize?(window, to: size) ?? size
            window.setFrame(frame, display: true); await delay(0.35)
        }
        func capture() async { model.screenshots.capture(model: model); await model.screenshots.finishPendingCapture(); await delay(0.05) }
        func image() -> NSBitmapImageRep? { model.screenshots.pasteboard.data(forType: .png).flatMap(NSBitmapImageRep.init(data:)) }
        func saveImage(_ name: String) {
            try? model.screenshots.pasteboard.data(forType: .png)?.write(to: output.appendingPathComponent(name + ".png"))
        }
        func differences(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep, above: Double) -> Int {
            guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else { return -1 }
            var count = 0
            for y in stride(from: 0, to: Int(Double(first.pixelsHigh) * above), by: 8) {
                for x in stride(from: 0, to: first.pixelsWide, by: 8) {
                    guard let a = first.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let b = second.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.06 { count += 1 }
                }
            }; return count
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        window.ignoresMouseEvents = true; model.chrome.hold(.keyboard, active: true)
        model.settings.autoSearch = false; model.settings.mfa = "/missing/toolbar-smoke"; model.player.set("mute", "yes")
        let directory = output.appendingPathComponent("saved")
        if restore {
            record("destinations-and-directory-restored", model.viewing.screenshot.clipboard && model.viewing.screenshot.file && model.viewing.screenshot.directory == directory.path)
            record("custom-screenshot-shortcut-restored", model.preferences.shortcut(for: .screenshot) == Shortcut(22, "6", [.command, .option]))
            record("small-free-window-restored", !model.viewing.fitVideoWindow && window.contentView?.bounds.size == NSSize(width: 680, height: 360), "\(window.frame)")
        } else {
            await delay()
            record("default-clipboard-only", model.viewing.screenshot.clipboard && !model.viewing.screenshot.file)
            record("camera-disabled-without-video", value("capture-screenshot", "accessibilityEnabled") as? Bool == false)
            record("symbols-available", ["camera", "aspectratio", "arrow.up.left.and.arrow.down.right", "arrow.down.right.and.arrow.up.left"].allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
        }
        model.open(video)
        let loaded = await wait { model.playbackReady && !model.english.isEmpty && !model.chinese.isEmpty && model.videoView.renderedFrames > 2 }
        record("video-and-subtitles-loaded", loaded)
        await model.openTask?.value; model.aligner.cancel(); await model.aligner.waitForCancellation()
        if model.endGate.wantsPlayback { model.togglePlayback() }
        model.setSidebarCollapsed(true); model.seek(1)
        _ = await wait { model.seekTarget == nil }; await delay(0.6)
        if loaded && !restore {
            record("tools-have-hover-help", toolIDs.allSatisfy { !(value($0, "accessibilityHelp") as? String ?? "").isEmpty })
            record("fit-icon-enables-mode", await press("fit-video-window") && model.viewing.fitVideoWindow)
            record("fit-button-shows-feedback", model.chrome.feedback?.title == "无黑边已开启")
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(window.contentView)
            let metrics = OperationMetrics.shared; metrics.enabled = true
            let firstRevision = metrics.revision
            await key(PlayerAction.toggleFitVideoWindow.defaultShortcut)
            record("fit-shortcut-dispatches-once-and-shows-feedback", metrics.revision == firstRevision + 1 && !model.viewing.fitVideoWindow && model.chrome.feedback?.title == "无黑边已关闭")
            await key(PlayerAction.toggleFitVideoWindow.defaultShortcut, repeatKey: true)
            record("held-fit-shortcut-does-not-repeat", !model.viewing.fitVideoWindow && metrics.revision == firstRevision + 1)
            await key(PlayerAction.toggleFitVideoWindow.defaultShortcut)
            let normalHelp = value("toggle-fullscreen", "accessibilityHelp") as? String
            _ = await press("toggle-fullscreen")
            let entered = await wait { model.windowPresentation.isFullScreen && !model.windowPresentation.isTransitioning }; await delay(0.6)
            record("fullscreen-button-syncs-window", entered && window.styleMask.contains(.fullScreen) && value("toggle-fullscreen", "accessibilityHelp") as? String != normalHelp)
            record("fullscreen-entry-shows-feedback", model.chrome.feedback?.title == "已进入全屏")
            model.togglePlayback(); await delay(0.3)
            await capture()
            record("fullscreen-capture-keeps-playing", image() != nil && model.endGate.wantsPlayback && !model.paused)
            model.togglePlayback(); model.seek(1); _ = await wait { model.seekTarget == nil }
            window.toggleFullScreen(nil)
            let exited = await wait { !model.windowPresentation.isFullScreen && !model.windowPresentation.isTransitioning }; await delay(0.6)
            record("native-fullscreen-exit-syncs-toolbar", exited && !window.styleMask.contains(.fullScreen))
            record("native-fullscreen-exit-shows-feedback", model.chrome.feedback?.title == "已恢复窗口")
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(window.contentView)
            await key(PlayerAction.toggleFullScreen.defaultShortcut)
            let keyedEntry = await wait { model.windowPresentation.isFullScreen && !model.windowPresentation.isTransitioning }
            record("fullscreen-shortcut-enters-with-feedback", keyedEntry && model.chrome.feedback?.title == "已进入全屏")
            await key(PlayerAction.toggleFullScreen.defaultShortcut, repeatKey: true); await delay(0.3)
            record("held-fullscreen-shortcut-does-not-repeat", model.windowPresentation.isFullScreen && !model.windowPresentation.isTransitioning)
            await key(PlayerAction.toggleFullScreen.defaultShortcut)
            let keyedExit = await wait { !model.windowPresentation.isFullScreen && !model.windowPresentation.isTransitioning }; await delay(0.5)
            record("fullscreen-shortcut-restores-with-feedback", keyedExit && model.chrome.feedback?.title == "已恢复窗口")
            model.chrome.resetNotice()
            model.chrome.resetFeedback()
            let original = window.frame
            var small = original
            small.size = window.delegate?.windowWillResize?(window, to: NSSize(width: 540, height: 300)) ?? small.size
            window.setFrame(small, display: true); await delay(0.6)
            let title = (value("playback-title", "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            let transport = (value("action-playPause", "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            let camera = (value("capture-screenshot", "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            record("compact-wide-window-keeps-tools-and-title-visible", !title.isEmpty && window.frame.contains(transport) && window.frame.contains(camera) && transport.maxY < title.minY)
            record("minimum-fit-window-keeps-single-row", singleRow())
            _ = WindowSnapshot.save(window, to: output.appendingPathComponent("compact-toolbar.png"))
            let fittedMinimum = window.frame.size
            model.perform(.toggleFitVideoWindow); await delay()
            record("turning-fit-off-does-not-enlarge-window", window.frame.size == fittedMinimum)
            await resize(NSSize(width: 100, height: 100))
            record("free-window-reaches-common-minimum", model.videoView.bounds.size == NSSize(width: 680, height: 360) && singleRow(), "\(model.videoView.bounds)")
            _ = WindowSnapshot.save(window, to: output.appendingPathComponent("minimum-free-toolbar.png"))
            model.setSidebarCollapsed(false); await delay()
            await resize(NSSize(width: 100, height: 100))
            record("sidebar-preserves-single-row-stage", model.videoView.bounds.width == 680 && singleRow())
            model.setSidebarCollapsed(true); model.perform(.toggleFitVideoWindow); await delay()
            window.setFrame(original, display: true); await delay(0.6)
            var preferences = ScreenshotPreferences()
            let forbidden = output.appendingPathComponent("clipboard-must-not-create")
            preferences.directory = forbidden.path; model.viewing.setScreenshot(preferences)
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(window.contentView)
            let screenshotRevision = metrics.revision
            await key(PlayerAction.screenshot.defaultShortcut); await model.screenshots.finishPendingCapture()
            record("screenshot-shortcut-dispatches-once", metrics.revision == screenshotRevision + 1 && metrics.action == .screenshot)
            let clipboardVersion = model.screenshots.pasteboard.changeCount
            await key(PlayerAction.screenshot.defaultShortcut, repeatKey: true)
            record("held-screenshot-shortcut-does-not-repeat", model.screenshots.pasteboard.changeCount == clipboardVersion)
            let bilingual = image(); saveImage("bilingual-capture")
            record("clipboard-image-has-video-size", bilingual?.pixelsWide == Int(model.videoView.bounds.width * window.backingScaleFactor) && bilingual?.pixelsHigh == Int(model.videoView.bounds.height * window.backingScaleFactor))
            record("clipboard-only-never-creates-folder", !FileManager.default.fileExists(atPath: forbidden.path) && model.screenshots.lastFile == nil)
            record("clipboard-png-and-tiff-and-message", bilingual != nil && model.screenshots.pasteboard.data(forType: .tiff).flatMap(NSBitmapImageRep.init(data:)) != nil && model.screenshots.lastMessage == "截图保存成功至剪贴板")
            _ = WindowSnapshot.save(window, to: output.appendingPathComponent("toolbar-window.png"))
            model.setSubtitleDisplay(.hidden); await delay(); await capture()
            let hidden = image(); saveImage("hidden-capture")
            if let bilingual, let hidden {
                record("subtitles-only-change-caption-region", differences(bilingual, hidden, above: 0.6) == 0 && differences(bilingual, hidden, above: 1) > 10)
            } else { record("subtitles-only-change-caption-region", false) }
            model.setSubtitleDisplay(.english); await delay(); await capture()
            let english = image(); saveImage("english-capture")
            record("english-mode-omits-chinese", bilingual != nil && english != nil && differences(bilingual!, english!, above: 1) > 5)
            model.setSubtitleDisplay(.bilingual); await delay()
            preferences.clipboard = false; preferences.file = true; preferences.directory = directory.path
            model.viewing.setScreenshot(preferences)
            let clipboardChange = model.screenshots.pasteboard.changeCount
            await capture()
            let fileOnly = model.screenshots.lastFile
            record("file-only-creates-png-without-touching-clipboard", fileOnly.flatMap { NSImage(contentsOf: $0) } != nil && model.screenshots.pasteboard.changeCount == clipboardChange && model.screenshots.lastMessage.contains("文件："))
            preferences.clipboard = true; model.viewing.setScreenshot(preferences)
            await capture(); let firstFile = model.screenshots.lastFile
            model.screenshots.capture(model: model); model.screenshots.capture(model: model)
            await model.screenshots.finishPendingCapture()
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            record("both-destinations-unique-files-and-busy-guard", firstFile != nil && firstFile != model.screenshots.lastFile && files.count == 3 && files.allSatisfy { $0.pathExtension == "png" } && model.screenshots.lastMessage.contains("剪贴板、文件："))
            let invalid = output.appendingPathComponent("regular-file")
            try? Data("not a directory".utf8).write(to: invalid)
            preferences.directory = invalid.path; model.viewing.setScreenshot(preferences)
            await capture()
            record("partial-failure-reports-clipboard-success-and-file-error", model.screenshots.lastFile == nil && model.screenshots.lastMessage.contains("截图保存成功至剪贴板\n文件保存失败"))
            preferences.clipboard = false; model.viewing.setScreenshot(preferences); await capture()
            record("file-failure-never-reports-success", !model.screenshots.lastMessage.contains("成功") && model.screenshots.lastMessage.contains("文件保存失败"))
            model.viewing.setScreenshot(ScreenshotPreferences())
            let editor = NSTextView(frame: NSRect(x: 10, y: 10, width: 200, height: 40))
            window.contentView?.addSubview(editor); window.makeFirstResponder(editor)
            record("text-input-keeps-new-shortcuts", [PlayerAction.toggleFullScreen, .toggleFitVideoWindow, .screenshot].allSatisfy { keyboard.handle(keyEvent($0.defaultShortcut)) != nil })
            editor.removeFromSuperview(); window.makeFirstResponder(window.contentView)
            model.settingsPage = 1; model.showSettings = true; await delay(0.6)
            record("new-actions-appear-in-shortcut-settings", [PlayerAction.toggleFullScreen, .toggleFitVideoWindow, .screenshot].allSatisfy { node("shortcut-binding-" + $0.rawValue) != nil })
            record("settings-block-new-actions", [PlayerAction.toggleFullScreen, .toggleFitVideoWindow, .screenshot].allSatisfy { keyboard.handle(keyEvent($0.defaultShortcut)) != nil })
            _ = await press("shortcut-binding-screenshot")
            let customScreenshot = Shortcut(22, "6", [.command, .option])
            await key(customScreenshot)
            record("native-shortcut-recording-updates-screenshot", model.preferences.shortcut(for: .screenshot) == customScreenshot && model.recordingAction == nil)
            model.showSettings = false; await delay(0.4)
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(window.contentView)
            let beforeCustom = metrics.revision
            await key(PlayerAction.screenshot.defaultShortcut)
            record("rebound-shortcut-disables-old-chord", metrics.revision == beforeCustom)
            await key(customScreenshot); await model.screenshots.finishPendingCapture()
            record("custom-screenshot-chord-and-help-update", metrics.revision == beforeCustom + 1 && model.screenshots.lastMessage == "截图保存成功至剪贴板" && (value("capture-screenshot", "accessibilityHelp") as? String)?.contains(customScreenshot.label) == true)
            metrics.enabled = false
            model.settingsPage = 2; model.showSettings = true; await delay(0.7)
            record("advanced-screenshot-page-shown", node("screenshot-save-clipboard") != nil && node("screenshot-directory") != nil)
            if let settings = NSApp.windows.first(where: { $0 !== window && $0.isVisible && find($0, "screenshot-directory") != nil }) {
                _ = WindowSnapshot.save(settings, to: output.appendingPathComponent("screenshot-settings.png"))
            }
            _ = await press("screenshot-save-clipboard")
            record("empty-destinations-disable-save", value("save-screenshot-settings", "accessibilityEnabled") as? Bool == false)
            _ = await press("screenshot-save-file"); _ = await press("screenshot-save-clipboard")
            if let field = node("screenshot-directory"), field.responds(to: NSSelectorFromString("setAccessibilityValue:")) { _ = field.perform(NSSelectorFromString("setAccessibilityValue:"), with: directory.path) }
            await page(0); await page(2)
            record("settings-tabs-retain-screenshot-draft", value("screenshot-directory") as? String == directory.path)
            _ = await press("choose-screenshot-directory")
            let opened = await wait { NSApp.windows.contains { $0 is NSOpenPanel && $0.isVisible } }
            if let panel = NSApp.windows.first(where: { $0 is NSOpenPanel && $0.isVisible }) as? NSOpenPanel {
                record("directory-chooser-mode", opened && panel.canChooseDirectories && !panel.canChooseFiles && panel.canCreateDirectories)
                panel.cancel(nil)
            } else { record("directory-chooser-mode", false) }
            _ = await wait { !model.filePanels.isPresenting }; await delay()
            record("cancel-folder-chooser-keeps-draft", model.showSettings && value("screenshot-directory") as? String == directory.path)
            _ = await press("save-screenshot-settings")
            record("save-settings-persists-both-destinations", !model.showSettings && model.viewing.screenshot.clipboard && model.viewing.screenshot.file && model.viewing.screenshot.directory == directory.path)
            model.chooseVideo()
            _ = await wait { NSApp.windows.contains { $0 is NSOpenPanel && $0.isVisible } }
            if let panel = NSApp.windows.first(where: { $0 is NSOpenPanel && $0.isVisible }) as? NSOpenPanel {
                record("video-chooser-resets-folder-mode", panel.canChooseFiles && !panel.canChooseDirectories && !panel.canCreateDirectories); panel.cancel(nil)
            } else { record("video-chooser-resets-folder-mode", false) }
            _ = await wait { !model.filePanels.isPresenting }; await delay()
            // A short screen cannot fit a portrait video's ratio and toolbar width simultaneously.
            model.open(video.deletingLastPathComponent().appendingPathComponent("Portrait.mp4"))
            _ = await wait { model.playbackReady && (model.videoAspect ?? 1) < 1 }
            await model.openTask?.value; model.aligner.cancel(); await model.aligner.waitForCancellation()
            var frame = window.frame
            frame.size = window.delegate?.windowWillResize?(window, to: NSSize(width: 330, height: frame.height)) ?? frame.size
            window.setFrame(frame, display: true); await delay(0.7)
            record("narrow-window-keeps-all-tools-visible", toolIDs.allSatisfy { id in
                guard let rect = value(id, "accessibilityFrame") as? NSValue else { return false }; return window.frame.contains(rect.rectValue)
            })
            record("portrait-toolbar-never-wraps", singleRow())
            _ = WindowSnapshot.save(window, to: output.appendingPathComponent("portrait-toolbar.png"))
            model.stopMedia(); await delay()
            record("camera-disabled-after-stop", value("capture-screenshot", "accessibilityEnabled") as? Bool == false)
            model.viewing.setFitVideoWindow(false); await delay()
            await resize(NSSize(width: 680, height: 360))
            record("empty-player-keeps-single-row", singleRow())
        }
        await model.store?.flush()
        let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(restore ? "toolbar-restore.json" : "toolbar.json"))
        model.screenshots.pasteboard.releaseGlobally(); NSApp.terminate(nil)
    }
}
