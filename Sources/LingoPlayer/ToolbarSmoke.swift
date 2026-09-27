import AppKit
import PlayerCore

/// Uses an isolated pasteboard and data directory; never changes the user's clipboard.
@MainActor enum ToolbarSmoke {
    static func run(model: AppModel, window: NSWindow, video: URL, output: URL, restore: Bool) async {
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
            let toolIDs = ["fit-video-window", "toggle-fullscreen", "capture-screenshot", "quick-settings", "action-playPause", "toggle-sidebar", "volume-control"]
            record("tools-have-hover-help", toolIDs.allSatisfy { !(value($0, "accessibilityHelp") as? String ?? "").isEmpty })
            record("fit-icon-enables-mode", await press("fit-video-window") && model.viewing.fitVideoWindow)
            let normalHelp = value("toggle-fullscreen", "accessibilityHelp") as? String
            _ = await press("toggle-fullscreen")
            let entered = await wait { model.windowPresentation.isFullScreen && !model.windowPresentation.isTransitioning }; await delay(0.6)
            record("fullscreen-button-syncs-window", entered && window.styleMask.contains(.fullScreen) && value("toggle-fullscreen", "accessibilityHelp") as? String != normalHelp)
            model.togglePlayback(); await delay(0.3)
            await capture()
            record("fullscreen-capture-keeps-playing", image() != nil && model.endGate.wantsPlayback && !model.paused)
            model.togglePlayback(); model.seek(1); _ = await wait { model.seekTarget == nil }
            window.toggleFullScreen(nil)
            let exited = await wait { !model.windowPresentation.isFullScreen && !model.windowPresentation.isTransitioning }; await delay(0.6)
            record("native-fullscreen-exit-syncs-toolbar", exited && !window.styleMask.contains(.fullScreen))
            model.chrome.resetNotice()
            let original = window.frame
            var small = original
            small.size = window.delegate?.windowWillResize?(window, to: NSSize(width: 540, height: 300)) ?? small.size
            window.setFrame(small, display: true); await delay(0.6)
            let title = (value("playback-title", "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            let transport = (value("action-playPause", "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            let camera = (value("capture-screenshot", "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            record("compact-wide-window-keeps-tools-and-title-visible", !title.isEmpty && window.frame.contains(transport) && window.frame.contains(camera) && transport.maxY < title.minY)
            _ = WindowSnapshot.save(window, to: output.appendingPathComponent("compact-toolbar.png"))
            window.setFrame(original, display: true); await delay(0.6)
            var preferences = ScreenshotPreferences()
            let forbidden = output.appendingPathComponent("clipboard-must-not-create")
            preferences.directory = forbidden.path; model.viewing.setScreenshot(preferences)
            _ = await press("capture-screenshot"); await model.screenshots.finishPendingCapture()
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
            // A portrait fixture makes the fit-mode window narrow enough for all three toolbar rows.
            model.open(video.deletingLastPathComponent().appendingPathComponent("Portrait.mp4"))
            _ = await wait { model.playbackReady && (model.videoAspect ?? 1) < 1 }
            await model.openTask?.value; model.aligner.cancel(); await model.aligner.waitForCancellation()
            var frame = window.frame
            frame.size = window.delegate?.windowWillResize?(window, to: NSSize(width: 330, height: frame.height)) ?? frame.size
            window.setFrame(frame, display: true); await delay(0.7)
            record("narrow-window-keeps-all-tools-visible", toolIDs.allSatisfy { id in
                guard let rect = value(id, "accessibilityFrame") as? NSValue else { return false }; return window.frame.contains(rect.rectValue)
            })
            _ = WindowSnapshot.save(window, to: output.appendingPathComponent("portrait-toolbar.png"))
            model.stopMedia(); await delay()
            record("camera-disabled-after-stop", value("capture-screenshot", "accessibilityEnabled") as? Bool == false)
        }
        await model.store?.flush()
        let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(restore ? "toolbar-restore.json" : "toolbar.json"))
        model.screenshots.pasteboard.releaseGlobally(); NSApp.terminate(nil)
    }
}
