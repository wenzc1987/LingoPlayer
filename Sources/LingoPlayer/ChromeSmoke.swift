import AppKit
import PlayerCore

@MainActor enum ChromeSmoke {
    static func run(model: AppModel, window: NSWindow, video: URL, output: URL) async {
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail]); print(name, passed, detail); fflush(stdout)
        }
        func delay(_ value: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(value * 1e9)) }
        func wait(_ predicate: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(12)
            while Date() < end { if predicate() { return true }; await delay(0.025) }; return predicate()
        }
        func screenshot(_ name: String) { record("screenshot_" + name, WindowSnapshot.save(window, to: output.appendingPathComponent(name + ".png"))) }
        func element(_ root: NSObject, id: String, depth: Int = 0) -> NSObject? {
            guard depth < 30 else { return nil }
            let identifier = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
            if root.responds(to: identifier), root.perform(identifier)?.takeUnretainedValue() as? String == id { return root }
            if root.responds(to: children), let items = root.perform(children)?.takeUnretainedValue() as? [Any] {
                for item in items { if let item = item as? NSObject, let found = element(item, id: id, depth: depth + 1) { return found } }
            }
            return nil
        }
        func click(_ point: NSPoint, in target: NSWindow? = nil) async {
            let target = target ?? window
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
                await delay(0.04)
            }
            await delay()
        }
        func clickButton(_ id: String) async -> Bool {
            for target in [window] + NSApp.windows.filter({ $0 !== window && $0.isVisible }) {
                guard let button = element(target, id: id), let value = button.value(forKey: "accessibilityFrame") as? NSValue else { continue }
                let rect = value.rectValue
                await click(target.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY)), in: target); return true
            }
            return false
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        model.settings.autoSearch = false; model.settings.mfa = "/missing/chrome-smoke"; model.setVolume(0); model.player.set("mute", "yes")
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        screenshot("empty")
        model.open(video)
        let loaded = await wait { model.playbackReady && !model.english.isEmpty && model.videoView.renderedFrames > 2 }
        record("video_loaded", loaded)
        if loaded, let cue = model.english.first, let word = cue.tokens.first(where: \.isWord) {
            if model.endGate.wantsPlayback { model.togglePlayback() }
            model.setSidebarCollapsed(true); model.seek(cue.start + 0.1)
            _ = await wait { model.seekTarget == nil && model.paused }; await delay(0.5)
            model.aligner.cancel(); await model.aligner.waitForCancellation()
            let failureKey = model.alignmentTaskStatus.message
            model.chrome.showNotice("字幕任务状态提示", key: failureKey)
            await delay(5.2)
            model.chrome.showNotice("字幕任务状态提示", key: failureKey)
            record("notice_expires_and_repeated_failure_stays_quiet", model.chrome.notice == nil)
            model.timings = [.init(cueID: cue.id, tokenIndex: word.id, start: cue.start, end: cue.end)]
            model.refreshLearning(); model.chrome.show()
            let stage = model.videoView.bounds.size
            record("video_fills_content_without_reserved_bars", stage.width > window.contentView!.bounds.width - 2 && stage.height >= window.contentView!.bounds.height - 2, "video=\(stage), content=\(window.contentView!.bounds.size)")
            screenshot("paused")
            await delay(3.2); record("paused_controls_stay_visible", model.chrome.visible)
            let midpoint = model.videoView.convert(NSPoint(x: stage.width / 2, y: stage.height / 2), to: nil)
            await click(midpoint)
            record("blank_click_hides_without_playing", !model.chrome.visible && model.paused)
            screenshot("immersive")
            await click(midpoint)
            record("blank_click_reveals_without_playing", model.chrome.visible && model.paused && model.videoView.bounds.size == stage, "visible=\(model.chrome.visible), paused=\(model.paused), holds=\(model.chrome.state.holds)")
            model.chrome.show(); await delay(0.3)
            let queueClicked = await clickButton("open-queue")
            record("toolbar_queue_opens_shared_sidebar", queueClicked && !model.preferences.sidebarCollapsed && model.sidebarTab == .queue)
            screenshot("queue")
            let menuClicked = await clickButton("subtitle-menu")
            let transcriptClicked = await clickButton("open-transcript")
            await delay(); screenshot("transcript")
            record("transcript_uses_same_sidebar", menuClicked && transcriptClicked && !model.preferences.sidebarCollapsed && model.sidebarTab == .transcript && stage.width - model.videoView.bounds.width > 300)
            model.setSidebarCollapsed(true); await delay()
            let wordClicked = await clickButton("subtitle-word-\(cue.id)-\(word.id)")
            record("floating_word_click_pauses_and_opens_learning", wordClicked && model.learning.isLocked && model.paused && !model.preferences.sidebarCollapsed && model.sidebarTab == .learning, "clicked=\(wordClicked), locked=\(model.learning.isLocked), collapsed=\(model.preferences.sidebarCollapsed), tab=\(model.sidebarTab)")
            await delay(0.5); screenshot("learning")
            model.resumeLearning(); await delay()
            record("continue_keeps_sidebar_and_unfolded_tab", !model.paused && !model.preferences.sidebarCollapsed && model.sidebarTab == .learning && !model.learning.isLocked)
            _ = await wait { !model.chrome.visible }
            record("playing_controls_auto_hide", !model.chrome.visible)
            let hiddenWordClicked = await clickButton("subtitle-word-\(cue.id)-\(word.id)")
            record("word_remains_clickable_with_controls_hidden", hiddenWordClicked && model.learning.isLocked && model.paused && model.chrome.visible)
            model.resumeLearning(); await delay()
            model.chrome.show(); await delay(0.3)
            let settingsClicked = await clickButton("quick-settings"); await delay(3.2)
            record("toolbar_settings_opens_popover", settingsClicked && model.showSubtitleControls)
            record("configuration_prevents_auto_hide", model.chrome.visible && model.chrome.state.holds.contains(.presentation))
            screenshot("settings")
            for (index, popup) in NSApp.windows.filter({ $0 !== window && $0.isVisible && $0.frame.width > 200 }).enumerated() {
                record("screenshot_settings_popup_\(index)", WindowSnapshot.save(popup, to: output.appendingPathComponent("settings-popup-\(index).png")))
            }
            model.showSubtitleControls = false
            if model.endGate.wantsPlayback { model.togglePlayback() }
            model.setSidebarCollapsed(true); model.setSubtitleDisplay(.hidden); await delay()
            record("hidden_subtitles_do_not_resize_video", model.videoView.bounds.size == stage)
            model.setSubtitleDisplay(.bilingual)
            window.setContentSize(NSSize(width: 980, height: 640)); model.openSidebar(.learning); await delay(0.5)
            screenshot("minimum")
            record("minimum_window_keeps_control_actions_available", element(window, id: "action-playPause") != nil && element(window, id: "open-queue") != nil)
            let originalEnglish = model.english
            let longCue = SubtitleCue(id: "layout-long", start: 0, end: model.duration, text: "Sometimes it takes a little time to understand what someone is saying, so we can listen again and learn together.")
            model.english = [longCue]; model.learning.resumeFollowing(); model.refreshLearning(); await delay(0.3)
            let wordRects = longCue.tokens.filter(\.isWord).compactMap { token -> CGRect? in
                (element(window, id: "subtitle-word-\(longCue.id)-\(token.id)")?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
            }
            let playRect = (element(window, id: "action-playPause")?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            record("long_subtitle_wraps_below_controls", wordRects.count == longCue.tokens.filter(\.isWord).count && (wordRects.first?.minY ?? 0) > (wordRects.last?.minY ?? 0) && wordRects.allSatisfy { $0.maxY < playRect.minY && window.frame.contains($0) })
            screenshot("long-subtitle")
            model.english = originalEnglish; model.refreshLearning()
            model.setSidebarCollapsed(true); window.toggleFullScreen(nil); await delay(1.5)
            record("native_fullscreen", window.styleMask.contains(.fullScreen)); screenshot("fullscreen")
            window.toggleFullScreen(nil); await delay(1.2)
        }
        let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("chrome.json"))
        NSApp.terminate(nil)
    }
}
